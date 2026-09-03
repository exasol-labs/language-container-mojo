# Build, test, package, register — native Mojo container

## 1. Build the binary (links libzmq)

```bash
mojo build src/main.mojo -o mojoudfclient
```
- **No link flags.** `src/zmq.mojo` `dlopen`s libzmq at runtime via
  `DLHandle("libzmq.so.5")` + `get_function[...]`, sidestepping `mojo build`'s
  linker entirely (it accepts C-library links only through `-Xlinker <ARG>`, and
  some versions can't link C libs at build time at all — modular/modular#3262).
- Because libzmq is `dlopen`'d, it will **not** appear in `ldd mojoudfclient`, so
  the container must stage `libzmq.so.5` (and its own dependency closure)
  explicitly. The Dockerfile does this (installs `libzmq5`, stages its closure).
  At runtime the loader finds it via the staged `/usr/lib/<triplet>/libzmq.so.5`.

## 2. Test locally against the fake DB (no Exasol needed)

`test/fake_exasol.py` binds a ZMQ **REP** socket and plays Exasol's side of the
protocol for `double`: it runs the handshake, sends one MT_NEXT batch of BIGINTs,
and asserts the container's MT_EMIT equals the doubled values. This is the
fastest way to debug the wire code.

```bash
pip install pyzmq
```
```bash
python3 test/fake_exasol.py --bind tcp://127.0.0.1:6583 --expect-double &
```
```bash
./mojoudfclient tcp://127.0.0.1:6583 lang=mojo
```
The harness prints `OK: doubling verified` and exits 0 on success. Iterate here
until green **before** touching a real database — the failure messages point at
the exact message/field that diverged.

## 3. Package the SLC tarball

Use the provided [`Dockerfile`](Dockerfile) — it builds `mojoudfclient` on Debian
trixie (matching Exasol's glibc), then stages a hermetic rootfs containing the
binary at `/exaudf/mojoudfclient`, its dynamic loader, its **full `ldd`
shared-object closure** (libzmq + the Mojo runtime libs), and the mount points
required by Nano's read-only `nschroot` sandbox (`/tmp`, `/var/tmp`, `/buckets`,
`/dev`, `/proc`, `/sys`, and `/run/secrets`). It runs a chroot self-test and
emits the SLC tarball:

```bash
docker build -f Dockerfile --target artifact --output type=local,dest=./out .
```
(Build context is this `native-mojo/` directory.) The tarball lands at
`out/mojo-slc.tar.gz`.

Two `VERIFY` spots in the Dockerfile need checking against your Mojo release: the
install channel (`pip install modular==$MOJO_VERSION`) and the `mojo build … -l
zmq` link invocation. Static-linking libzmq lets you drop `libzmq.so.5` from the
staged closure. If steps 1–2 built the binary another way, set
`SLC_TARBALL`-style skip logic or just copy your binary into the builder stage.

## 4. Upload + register the MOJO alias

**One command** — `install-native.sh` builds (step 3), uploads to BucketFS, and
registers the `MOJO` alias, preserving every other language already installed:

```bash
./install-native.sh --host localhost --password exasol --bfs-password secret
```
Flags: `--port/--user/--bfs-port/--bucket/--bfs-service/--slc-name/--scope`;
`MOJO_SLC_TARBALL=…` reuses a prebuilt tarball instead of running docker.

Or do it by hand — note the **executable name** in the fragment is
`mojoudfclient`, not `exaudfclient`:

```sql
ALTER SESSION SET SCRIPT_LANGUAGES=
 'MOJO=localzmq+protobuf:///bfsdefault/default/slc/mojoslc?lang=mojo#buckets/bfsdefault/default/slc/mojoslc/exaudf/mojoudfclient';
```

## 5. Create the script and run it

```sql
-- DOUBLE is an Exasol type keyword, so quote the baked-in script name.
CREATE OR REPLACE MOJO SCALAR SCRIPT myschema."DOUBLE"(val BIGINT)
RETURNS BIGINT AS
-- no %udf_object: the function is baked into the container binary,
-- selected by the script name DOUBLE.
this is the script body; the native container ignores it beyond the name;
/
```
```sql
SELECT myschema."DOUBLE"(21);   -- 42
```

> The body is required syntactically but unused (the native container dispatches
> on the script *name* `DOUBLE`). If your Exasol build rejects a non-empty body,
> use a single comment line.

## Debugging a live failure
- `22002 VM crashed` immediately → the binary or a runtime lib is missing/unloadable
  in the rootfs; re-check step 3 `ldd`.
- Hang, then timeout → a wire mismatch (a required field omitted, or a wrong field
  number). Reproduce with `test/fake_exasol.py` and compare frames.
- Wrong results → the `column_i64` cursor walk or the emit packing; the harness
  catches these deterministically.
