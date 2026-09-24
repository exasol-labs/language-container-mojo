# Native Mojo Script Language Container
[![CI](https://github.com/exasol-labs/language-container-mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/exasol-labs/language-container-mojo/actions/workflows/ci.yml)

A Script Language Container (SLC) for Exasol written **entirely in [Mojo](https://www.modular.com/mojo) — no Rust, no C++ host, no `.so` plugin loading.**
A single Mojo binary (`mojoudfclient`) speaks Exasol's ZMQ + protobuf UDF protocol
directly and runs the user function **in-process**:

```
Exasol DB  <== ZMQ REQ/REP + protobuf ==>  mojoudfclient   (one Mojo binary:
                                            protocol loop + your UDF, baked in)
                                              └ only external dependency: libzmq
```

Everything that a language container normally needs — the ZMQ transport, the
protobuf wire format, the handshake/run state machine, and the UDF itself — is
Mojo (protobuf is hand-rolled; libzmq is the sole C dependency, since Exasol's
protocol *is* `localzmq`). There is **no Rust anywhere**: no `exaudfclient`, no
C-ABI vtable, no fingerprint, no `dlopen` of a compiled `.so`.

> **Status — experimental.** The binary compiles (Linux ARM64/x86_64) and passes
> the full ZMQ/protobuf **offline self-test** (`test/fake_exasol.py`:
> `OK: doubling verified`). A complete *live* UDF invocation is still being
> finalized — see [Current limitations](#current-limitations) and the
> [diagnostic build](#diagnosing-a-live-run). Design details are in
> [`DESIGN.md`](DESIGN.md).

---

## Why a Mojo Script Language Container

A Script Language Container (SLC) is a self-contained runtime that you install into
Exasol so the database can execute user-defined functions (UDFs) in a language it
doesn't ship natively, letting you push custom logic to where the data lives instead
of pulling rows out to an external service. Running your code *inside* the database
this way eliminates network round-trips and serialization overhead, so heavy per-row
or per-group computation happens in-place, in parallel across Exasol's nodes. Mojo is
a compelling language for that hot path because it is a compiled, statically-typed
language that produces native machine code — no interpreter loop, no per-call bytecode
dispatch — making it dramatically faster than a scripting language for CPU-bound work.
At the same time Mojo is a member of the Python ecosystem: it interoperates with
CPython via `Python.import_module`, so you can reuse existing Python packages and
gradually move only the performance-critical parts to native Mojo. The result is a UDF
container that gives you Python's familiarity and libraries where you want them, and
compiled, close-to-the-metal speed where you need it — inside the database engine itself.

---

## When to reach for a UDF — and when to stay in SQL

**Try SQL first; drop to a UDF only when SQL can't express the work efficiently.**
Exasol's SQL engine is heavily optimized and massively parallel, so set-based
work — filters, joins, aggregations, window functions — belongs in SQL, where a
hand-written UDF would usually be slower and harder to maintain. A UDF earns its
place when the logic is a poor fit for relational algebra: complex per-row or
per-group procedures, iterative or stateful algorithms, custom parsing, or bespoke
numeric/string routines you'd otherwise pull out of the database into an external
service. The rule of thumb: if SQL becomes contorted, needs many passes, or simply
can't do it, that's when a UDF is worth it.

**Once you do need a UDF, Mojo is the fast path.** It compiles to native machine
code, so a CPU-bound hot path runs without an interpreter loop — often far faster
than a scripting-language UDF for the same inner computation. Because Mojo is part
of the Python ecosystem and calls CPython via `Python.import_module`, you don't
have to rewrite everything at once: **keep the bulk of your logic in Python and
move only the performance-critical inner loop to native Mojo**, incrementally.
When you want a fully compiled, dependency-light function, you can also write the
UDF **from scratch** in pure Mojo. Reach for this container when you've identified
a genuine hot path inside the database and want compiled speed there while keeping
Python's familiarity and libraries everywhere else.

---

## The workflow at a glance

1. [Write your UDF in Mojo](#1-write-your-udf-in-mojo) — `src/udf.mojo`
2. [Compile & self-test](#2-compile--self-test-no-exasol-needed) — no Exasol needed
3. [Build the SLC package](#3-build-the-slc-package) — one `docker`/`podman build`
4. Deploy: [**Personal** (`exasol slc custom install`)](#4a-deploy-to-exasol-personal-exasol-slc-custom-install) · [**Enterprise** (BucketFS via curl)](#4b-deploy-to-exasol-enterprise-bucketfs-via-curl) · [**Nano** (Docker execution environment)](#4c-deploy-to-exasol-nano-copy-the-directory)
5. [Activate the language container](#5-activate-the-language-container)
6. [Create the script and run it](#6-create-the-script-and-run-it)

---

## 1. Write your UDF in Mojo

The entire user-facing UDF lives in [`src/udf.mojo`](src/udf.mojo).
The shipped example doubles a `BIGINT`:

```mojo
# out[i] = 2 * in[i], with NULL in → NULL out  (SCALAR)
fn run_double_mojo(values: List[Int64], nulls: List[Bool]) -> (List[Int64], List[Bool]):
    var out = List[Int64]()
    var out_nulls = List[Bool]()
    for i in range(len(values)):
        if nulls[i]:
            out.append(0); out_nulls.append(True)
        else:
            out.append(values[i] * 2); out_nulls.append(False)
    return (out^, out_nulls^)

# Dispatch on the SQL script name (already UPPER-cased by Exasol).
fn run_udf(name: String, values: List[Int64], nulls: List[Bool]) -> (List[Int64], List[Bool]):
    if name == "SUM_POSITIVE":
        return run_sum_positive(values, nulls)   # SET reduce
    return run_double_mojo(values, nulls)        # DOUBLE_MOJO (default)

fn is_known(name: String) -> Bool:
    return name == "DOUBLE_MOJO" or name == "SUM_POSITIVE"
```

The scalar UDF is named `DOUBLE_MOJO` (not `DOUBLE`, a reserved Exasol keyword).

- **Change the logic:** to make it `triple`, change `values[i] * 2` to `* 3`.
- **Add a UDF:** implement another `run_*`, add an arm to `run_udf`, and add the
  name to `is_known`. The run loop in [`src/main.mojo`](src/main.mojo)
  collects a whole group and calls `run_udf` — a SCALAR UDF returns one row per
  input row (map), a SET UDF returns one row per group (reduce).
- Everything else (`proto.mojo`, `wire.mojo`, `zmq.mojo`, `main.mojo`) is the host
  plumbing — a UDF author normally doesn't touch it.

## 2. Compile & self-test (no Exasol needed)

The binary is built inside the container image (step 3), but you can also compile
directly with a local Mojo toolchain:

```bash
mojo build src/main.mojo -o mojoudfclient
```

No linker flags: `src/zmq.mojo` `dlopen`s `libzmq.so.5` at runtime, so `mojo build`
never touches the linker.

The fastest correctness check is the **self-test target**, which drives the real
binary in a chroot through the entire ZMQ/protobuf conversation against a bundled
fake Exasol — for **every** UDF/wire combination:

- `DOUBLE_MOJO` (scalar) and `SUM_POSITIVE` (set) over the INT64 block,
- `DOUBLE_MOJO` over the NUMERIC/string block,
- `PY_SCALE` (Python interop) — proving CPython initializes inside the sandbox.

```bash
docker build -f Dockerfile --target selftest --progress=plain .
```
(Use `podman build --arch arm64 …` on Apple Silicon.) Each case prints a
per-message trace (`CLIENT → META → RUN → NEXT → EMIT → DONE → FINISHED`) and an
`OK: <script> verified` line; the build fails if any case diverges — invaluable
for debugging the wire code before touching a database.

## 3. Build the SLC package

One build produces a hermetic rootfs tarball: the `mojoudfclient` binary, its
dynamic loader, its **full `ldd` shared-object closure** (libzmq + the Mojo
runtime libs), and the empty mount points Nano's read-only `nschroot` sandbox
requires (`/tmp`, `/var/tmp`, `/buckets`, `/dev`, `/proc`, `/sys`, `/run/secrets`).

```bash
# x86_64 host / Enterprise target
docker build -f Dockerfile --target artifact \
  --output type=local,dest=./out .
#  → out/mojo-slc.tar.gz
```

On Apple Silicon for **ARM64 Nano**, build with Podman and copy the tarball out of
the staging image, then unpack it into a rootfs directory to mount:

```bash
podman build --arch arm64 -f Dockerfile --target staging \
  -t mojo-slc:staging .

cid="$(podman create mojo-slc:staging)"
podman cp "$cid:/mojo-slc.tar.gz" ./mojo-slc.tar.gz
podman rm "$cid"

mkdir -p mojo-rootfs && tar -xzf mojo-slc.tar.gz -C mojo-rootfs
file mojo-rootfs/exaudf/mojoudfclient   # ARM64 Linux ELF on an ARM64 host
```

> Build the image for the **same architecture as the database container**. Never
> mount an ARM64 client into an x86_64 Exasol, or vice versa.

`build_info/language_definitions.json` in the rootfs declares the
`MOJO` alias and the executable path `/exaudf/mojoudfclient`.

## 4a. Deploy to Exasol Personal (`exasol slc custom install`)

Exasol Personal Edition installs a custom SLC directly with the `exasol` CLI —
no BucketFS upload or bind mounts. The container is given as `--source`, which
takes either a local tarball or an `https` URL, together with the `--alias` used
in `CREATE <alias> SCALAR SCRIPT` and the `--language` it provides:

```bash
exasol slc custom install \
  --source ./out/mojo-slc.tar.gz \
  --alias MOJO \
  --language mojo \
  --auto-approve
```

Like the official commands, a custom `install` (or `update`) **restarts the
database** to mount the container, so it accepts `--auto-approve` to skip the
confirmation and `--no-restart` to record the container and activate it on the
next start instead. If the container cannot be made available, the database
still starts and the command reports that the container is recorded but not
active.

`exasol slc list` now shows custom containers alongside the official ones with a
**status** column, and `--json` marks them with a `custom` type and an
`available` field.

## 4b. Deploy to Exasol Enterprise (BucketFS via curl)

Enterprise fetches the SLC from BucketFS over HTTP. Upload the tarball with a
single `curl` PUT — BucketFS **auto-extracts** `*.tar.gz`, so `slc/mojoslc.tar.gz`
becomes browsable at `slc/mojoslc/`:

```bash
HOST=my-exasol-host          # BucketFS service host

# -u w  → curl prompts for the write password (keeps it out of ps/history);
#         you upload the executable UDF binary here, so DON'T disable TLS in prod.
curl -X PUT -T out/mojo-slc.tar.gz -u w \
  "https://${HOST}:2581/default/slc/mojoslc.tar.gz"
```

- `w` is the BucketFS write user; `2581` is the HTTPS BucketFS port (`2580` for
  HTTP). **Validate TLS** — this channel carries the container binary, so a MITM
  could swap it. For a self-signed BucketFS cert use `--cacert <ca.pem>`; only add
  `-k` (skip verification) if you accept that risk.
- `default` is the bucket in the `bfsdefault` service. Verify the executable
  landed:
  ```bash
  curl -s -u r -o /dev/null -w '%{http_code}\n' \
    "https://${HOST}:2581/default/slc/mojoslc/exaudf/mojoudfclient"
  # 200 = present
  ```

`install-native.sh` wraps build + this upload + registration into one
command if you'd rather not do it by hand.

## 4c. Deploy to Exasol Nano (copy the directory)

Nano runs the whole Exasol database as a single local container, so **reach for
it when you require Docker (or Podman) as the execution environment** — local
development, CI, or a self-contained demo. It reads language metadata under
`/exa/slc` and launches UDFs in `/exa/sandbox` — **mount the same unpacked rootfs
at both paths** (this is the "copy it to the directory" step; a read-only bind
mount is the copy). Persist Nano's database files in `nano-exa`. On first init,
pass `builtinScriptLanguageName=slc/mojo` (persisted in `nano-exa/exasol.conf`;
omit `init params=…` on later starts). `--security-opt unmask=ALL` is required
for SLC/UDF execution.

```bash
mkdir -p nano-exa

podman run --rm -it --name exanano-mojo \
  --security-opt unmask=ALL --shm-size=512mb --pids-limit=-1 \
  -p 127.0.0.1:8563:8563 \
  -v "$PWD/nano-exa:/exa" \
  -v "$PWD/mojo-rootfs:/exa/slc/mojo:ro" \
  -v "$PWD/mojo-rootfs:/exa/sandbox:ro" \
  docker.io/exasol/nano:latest \
  init params='builtinScriptLanguageName=slc/mojo'
```

Wait for `Database is now up and running!`. Default SYS credentials are
`sys` / `exasol`. If port 8563 is taken, map another (e.g. `18563:8563`).

## 5. Activate the language container

Registration differs between deployments — this is the step that most often
trips people up.

**Personal** — nothing to do here: `exasol slc custom install --alias MOJO`
already registered the alias and restarted the database, so the language is
active immediately. Confirm with `exasol slc list` (the container shows as
`available`).

**Nano** — the SLC is mounted and named via `builtinScriptLanguageName`, so the
alias points at that built-in name:

```sql
ALTER SYSTEM SET SCRIPT_LANGUAGES = 'MOJO=builtin_mojo';
```

**Enterprise** — the alias is a `localzmq+protobuf` URL into BucketFS, ending at
the **executable** (`mojoudfclient`, no leading slash). `SCRIPT_LANGUAGES` holds
*all* languages, so preserve the existing ones (read them first, then re-set the
whole value):

```sql
SELECT system_value FROM EXA_PARAMETERS WHERE parameter_name = 'SCRIPT_LANGUAGES';
-- then, keeping the builtins that returns:
ALTER SYSTEM SET SCRIPT_LANGUAGES=
  'PYTHON3=builtin_python3 JAVA=builtin_java R=builtin_r MOJO=localzmq+protobuf:///bfsdefault/default/slc/mojoslc?lang=mojo#buckets/bfsdefault/default/slc/mojoslc/exaudf/mojoudfclient';
```

> `builtin_mojo` is **only** valid for the Nano mounted-SLC mechanism. On
> Enterprise it must be the full `localzmq+protobuf://…#…/mojoudfclient` URL —
> using `builtin_mojo` there yields *"No usable script language container"*.

New sessions pick up `ALTER SYSTEM` (reconnect first). Use `ALTER SESSION` with
the same value to test in the current session only.

## 6. Create the script and run it

The native client dispatches on the **SQL script name** (there is no
`%udf_object`); the script body is ignored. The container ships two baked-in
UDFs — `DOUBLE_MOJO` (SCALAR) and `SUM_POSITIVE` (SET). The scalar one is named
`DOUBLE_MOJO` rather than `DOUBLE` because `DOUBLE` is a reserved Exasol type
keyword.

```sql
CREATE SCHEMA IF NOT EXISTS MOJO_TEST;
OPEN SCHEMA MOJO_TEST;

-- SCALAR (map): out = 2 * val
CREATE OR REPLACE MOJO SCALAR SCRIPT DOUBLE_MOJO(val BIGINT)
RETURNS BIGINT AS
-- native client dispatches by script name; body ignored
/

-- SET (reduce): sum of positive values per group
CREATE OR REPLACE MOJO SET SCRIPT SUM_POSITIVE(val BIGINT)
RETURNS BIGINT AS
-- native client dispatches by script name; body ignored
/
```
```sql
SELECT DOUBLE_MOJO(21);     -- 42
SELECT DOUBLE_MOJO(-5);     -- -10
SELECT DOUBLE_MOJO(NULL);   -- NULL

SELECT SUM_POSITIVE(val) FROM (VALUES 10, 21, -5, 0, 7) t(val);   -- 38
```

Via `pyexasol` over a local TLS connection:

```bash
python3 - <<'PY'
import ssl, pyexasol
conn = pyexasol.connect(dsn='127.0.0.1:8563', user='sys', password='exasol',
                        encryption=True,
                        websocket_sslopt={'cert_reqs': ssl.CERT_NONE})
conn.execute('OPEN SCHEMA MOJO_TEST')
print(conn.execute('SELECT DOUBLE_MOJO(21)').fetchall())
conn.close()
PY
```

## Calling Python from a UDF (Python interop)

A Mojo UDF can call Python via Mojo's interop — `from python import Python` then
`Python.import_module("pkg.sub")`. The container bundles a **minimal CPython**
(interpreter + stdlib + `libpython`) into the rootfs so this works inside the
sandbox; `src/main.mojo` points `MOJO_PYTHON_LIBRARY`/`PYTHONHOME`/`PYTHONPATH`
at it at startup.

The shipped example is `PY_SCALE`, which imports the bundled module
[`python/pyudf/transform.py`](python/pyudf/transform.py) and calls `scale(v)`:

```mojo
# src/udf.mojo
from python import Python

fn run_py_scale(values: List[Int64], nulls: List[Bool]) raises -> (List[Int64], List[Bool]):
    var transform = Python.import_module("pyudf.transform")   # dotted import
    ...
    var r = transform.scale(values[i])                        # call the Python fn
    out.append(Int(r))
```
```sql
SELECT PY_SCALE(val) FROM (VALUES 10, 21, -5, 0, 7) t(val);   -- 100,210,-50,0,70
```

**Adding Python packages** — list them in [`requirements.txt`](requirements.txt)
(one per line, e.g. `numpy==2.1.0`) and rebuild. They're `pip install`ed into
`/opt/pypkgs` in the rootfs (on `PYTHONPATH`), so `Python.import_module("numpy")`
resolves. Your own modules go in `python/` (shipped to `/opt/pypkgs` too).

> Verified offline: `PY_SCALE` drives CPython inside the hermetic rootfs via the
> chroot self-test. Note each `import`/call crosses the Mojo↔Python boundary, so
> Python interop trades performance for library access — use it where the Python
> ecosystem earns its keep.

## Dynamic UDFs via shared objects (extension, no rebuild)

By default a UDF is compiled **into** `mojoudfclient`, so adding one means
rebuilding and redeploying the container. As an **opt-in extension**, you can
instead compile a UDF to a shared object, upload it to BucketFS, and point a
script at it with a `%udf_object` line — the container `dlopen`s it at run time
(analogous to the Rust SLC's `.so` model). Scripts *without* `%udf_object` keep
using the baked-in UDFs, so this adds a path, it doesn't change the default.

```mojo
# examples/udf_so/double_ext.mojo — exports the C ABI in src/loader.mojo
@export
fn __exa_udf_entry_DOUBLE_EXT(in_vals: UnsafePointer[Int64], in_nulls: UnsafePointer[Bool],
        n_in: Int64, out_vals: UnsafePointer[UnsafePointer[Int64]],
        out_nulls: UnsafePointer[UnsafePointer[Bool]]) -> Int64:
    ...   # allocate the output, return its row count (SET reduces, EMITS expands)
```

```bash
mojo build --emit shared-lib examples/udf_so/double_ext.mojo -o double_ext.so
# upload double_ext.so to BucketFS (curl, like section 4b), then:
```

```sql
CREATE OR REPLACE MOJO SCALAR SCRIPT DOUBLE_EXT(val BIGINT) RETURNS BIGINT AS
%udf_object /buckets/bfsdefault/default/udfs/double_ext.so
/
```

Hybrid Mojo+Python works here too: a `.so` that calls `Python.import_module`
reuses the CPython runtime bundled in the container (the `.so` ships no Python).
Two constraints: the `.so` must be built with the **same Mojo toolchain** as the
container (the host checks an ABI version and refuses a mismatch), and any extra
Python packages it imports must be on `PYTHONPATH` (bundled, or uploaded too).

**Full step-by-step (build → upload to BucketFS → register → run):
[`DYNAMIC_UDF.md`](DYNAMIC_UDF.md).** See also [`src/loader.mojo`](src/loader.mojo)
for the ABI and [`examples/udf_so/`](examples/udf_so/) for the template.

## Diagnosing a live run

If a live `SELECT DOUBLE_MOJO(21)` returns an empty set or `22002 VM crashed`, build
the **diagnostic** entry point instead of the normal one. It runs the handshake +
one input cycle and then reports exactly what Exasol sent — column types, row
count, and which wire block the value landed in — as the SQL error message:

```bash
docker build -f Dockerfile --target artifact \
  --build-arg ENTRY=diag.mojo --output type=local,dest=./diag-out .
```

Deploy `diag-out/mojo-slc.tar.gz` in place of the normal one and run the query;
it will fail with a line like:

```
MOJO-DIAG script=DOUBLE_MOJO in_iter=1 single=0 in_types=[..] out_types=[..] | RUN->6 rows=1 i64=1 str=0 first_i64=21
```

`in_types`/`out_types` are `column_type` enums (`3`=INT64, `4`=NUMERIC, `7`=STRING,
…); `i64=`/`str=` show which block the input value used. That tells you whether the
container must read/emit the NUMERIC/string block instead of `data_int64`.

## Testing

The suite is modelled on the Rust SLC's and has five offline layers plus a live
E2E, each wired into CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml),
[`.gitlab-ci.yml`](.gitlab-ci.yml)). Run everything with `make test` (or
`bash test/run-all.sh`); see [`TESTING.md`](TESTING.md) for how to run each layer
by hand.

| Layer | What it proves | Files | How it runs |
|-------|----------------|-------|-------------|
| **Codec unit tests** | The pure protobuf/wire functions (varint, int reinterpret, packed repeated, length-prefix bounds, decimal parsing, block mapping) are correct in isolation. Analogue of the Rust SLC's per-module `*_tests.rs`. | [`test/mojo/test_codec.mojo`](test/mojo/test_codec.mojo) | `make unittest` |
| **Protocol self-test** | The real `mojoudfclient` binary speaks the full ZMQ + protobuf `MT_*` exchange for every UDF/wire combination, incl. multi-batch accumulation. Covers all three UDF shapes: **SCALAR** (`DOUBLE_MOJO`, `PY_SCALE`), **SET** (`SUM_POSITIVE`), **EMITS** one-to-many (`MIRROR_MOJO`). | [`test/fake_exasol.py`](test/fake_exasol.py) | `make selftest` |
| **Datatype compatibility** | Every Exasol SQL column type is driven through the real binary and asserted to convert correctly or be refused with a precise `MT_CLOSE` — the contract of which SQL types map to a Mojo `Int64`. | [`test/fake_exasol.py`](test/fake_exasol.py) (`--coltype`) | `make selftest` |
| **Tarball contract** | The shipped SLC rootfs satisfies the sandbox contract: client present/executable and arch-matched, DT_NEEDED closure resolvable, bundled CPython staged, skeleton mount points, size ceiling, metadata byte-identical. Ported from `dist/tests/slc_tarball_test.sh`. | [`test/slc_tarball_test.sh`](test/slc_tarball_test.sh) | `make tarball` |
| **Language-definitions contract** | `build_info/language_definitions.json` conforms to the Exasol v2 metadata schema (aliases `MOJO`, `lang=mojo`, `localzmq+protobuf`, `/exaudf/mojoudfclient`, no legacy keys). One fixture per defect class proves each assertion discriminates. | [`test/language_definitions_test.sh`](test/language_definitions_test.sh), [`…_fixtures_test.sh`](test/language_definitions_fixtures_test.sh), [`fixtures/`](test/fixtures/language_definitions/) | `make contracts` |
| **E2E (real Exasol)** | The SLC deployed into a real Exasol, MOJO activated, and every UDF (SCALAR / SET / EMITS + INTEGER/DECIMAL inputs) exercised through actual SQL. Analogue of the Rust SLC's `it/db_roundtrip`. | [`test/e2e/e2e_test.py`](test/e2e/e2e_test.py) (pyexasol) | [`e2e.yml`](.github/workflows/e2e.yml) (GitHub x86_64) |

## Repository layout

The whole repo is the language container — everything is Mojo, no Rust.

```
src/udf.mojo          ← the UDFs: DOUBLE_MOJO, SUM_POSITIVE, PY_SCALE + dispatch
src/main.mojo         protocol host: argv → connect → handshake → run loop
src/diag.mojo         diagnostic entry point (reports Exasol's wire encoding)
src/wire.mojo         Exasol message encode/decode + exascript_table_data
src/proto.mojo        hand-rolled protobuf primitives
src/zmq.mojo          libzmq FFI (runtime dlopen)
Dockerfile            build binary + package hermetic SLC rootfs (incl. CPython)
build_info/…json      SLC self-description (MOJO alias → /exaudf/mojoudfclient)
install-native.sh     one command: build → BucketFS upload → register (Enterprise)
build.md              build / test / package / register runbook
DESIGN.md             architecture + the extracted Exasol wire-protocol reference
requirements.txt      extra Python packages to bundle (pip → /opt/pypkgs)
python/pyudf/         Python modules callable from UDFs via interop
test/fake_exasol.py   offline protocol oracle (the self-test)
test/diag_probe.py    offline check for the diagnostic build
examples/register.sql activate the language + create/call all three UDFs
examples/triple.mojo  worked example: adding a new native UDF
```
  
  
## Current limitations

- **Live e2e not confirmed green.** The self-test verifies the full wire protocol
  offline (INT64 and NUMERIC/string blocks, SCALAR and SET). A prior live run
  returned an empty result; the likely cause — Exasol delivering `BIGINT` in the
  NUMERIC/string block — is now handled, but a live run has not yet been
  re-confirmed. Use the [diagnostic build](#diagnosing-a-live-run) if it recurs.
- **The UDFs are hard-coded.** `src/udf.mojo` ships `DOUBLE_MOJO` (SCALAR),
  `SUM_POSITIVE` (SET), and `PY_SCALE` (SCALAR via Python interop), all
  `BIGINT → BIGINT`. To change/add a UDF, edit the `run_udf` dispatch +
  implementation, rebuild the SLC, and redeploy.
- **Python interop is available** (bundled CPython + stdlib; extra packages via
  `requirements.txt`). It adds ~17 MB to the rootfs and crosses the Mojo↔Python
  boundary per call — use it for library access, not hot numeric loops.
- **Column type coverage.** Integer columns are read/written across the `data_int64`,
  `data_int32`, and NUMERIC/DECIMAL `data_string` blocks. `DOUBLE` (floating point),
  other types, and EMITS (multi-row output) are not yet implemented; SET input
  (group reduce) is.
- **No `%udf_object` / arbitrary source.** The container has no dynamic `.so`
  loading and no JIT of the SQL script body.
- **Architecture-specific.** Build the image for the same arch as the database
  container (ARM64 for ARM64 Nano, x86_64 otherwise).
