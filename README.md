# Mojo UDFs for Exasol — design sketch (reuse the Rust host)

**Status:** the **host + registration side is implemented, compiled, and tested**
as `mojo-bridge.patch` against
[`exasol-labs/language-container-rs`](https://github.com/exasol-labs/language-container-rs)@`main`
(see the complete summary below and [PATCH.md](PATCH.md)). What is still a **design
sketch** is the Mojo-language side — the SDK ([sdk/](sdk)) and build tool
([tools/](tools)) — which uses approximate Mojo 1.0 syntax (flagged inline) and
needs a real Mojo toolchain to build. The Rust facts (symbol names, vtable layout,
proto messages) are pulled verbatim from the repo and are the source of truth.

## The idea in one line

Exasol's Script Language Container (SLC) protocol is language-agnostic. The Rust
project already implements the hard half — a container executable
(`exaudfclient`) that speaks **ZMQ REQ/REP + protobuf** to the database and
`dlopen`s a user-compiled `.so` at query time. We **reuse that host unchanged in
spirit** and only add: (1) a small C-ABI context bridge on the host side, (2) a
Mojo SDK that emits a conformant `.so`, (3) a build tool. Mojo never touches ZMQ
or protobuf.

```
Exasol DB  <--ZMQ/protobuf-->  exaudfclient (Rust host)  <--C ABI + dlopen-->  libyourudf.so (Mojo)
                                   ^ unchanged transport            ^ what we build
```

## `mojo-bridge.patch` — complete summary

One patch, applied to a fresh `language-container-rs` checkout, turns the Rust
host into one that also loads and registers Mojo UDFs. **15 files, +837 / −27.**
Apply/build/verify details are in [PATCH.md](PATCH.md); the working checkout with
it applied is under [repo/](repo).

### 1. Host C-ABI bridge — lets a non-Rust `.so` read inputs / write outputs
- `crates/exa-udf-runtime/src/c_ctx.rs` **(new)** — 19 `extern "C"` accessors
  (`exa_ctx_*`, `exa_alloc_cstring`), a thread-local multi-column emit-row buffer,
  a GC `anchor()`, unit tests. Undoes the host's double-indirected
  `&mut dyn UdfContext` exactly as `dispatch::invoke_run` erases it, then calls the
  real trait methods — so `Value` and the trait never cross the `.so` boundary.
- `crates/exa-udf-runtime/src/lib.rs` — `#[cfg(feature="mojo-bridge")] pub mod c_ctx;`
- `crates/exa-udf-runtime/Cargo.toml` — off-by-default `mojo-bridge` feature.

### 2. Load path — accept a Mojo `.so`'s fingerprint and the `lang=mojo` argument
- `crates/exa-udf-runtime/src/loader.rs` (+`loader_tests.rs`) — extracts
  `validate_fingerprint`; under the feature a `"mojo:<ver>"` fingerprint waives the
  rustc-hash equality (the `abi_version==7` check stays the structural guard).
  Default stays exact-match.
- `crates/exaudfclient/src/main.rs` (+`main_tests.rs`) — `is_supported_lang`
  accepts `lang=mojo` only under the feature (`lang=rust` always, others never);
  `main` calls `c_ctx::anchor()` so the linker keeps the exported symbols.
- `crates/exaudfclient/Cargo.toml` — forwards the `mojo-bridge` feature.
- `crates/exaudfclient/build.rs` **(new)** — links the binary `-rdynamic` (Linux)
  / `-export_dynamic` (macOS) under the feature, so the `dlopen`ed `.so` resolves
  the `exa_ctx_*` symbols from the host.

### 3. `MOJO` keyword + registration — one container, two aliases
- `build_info/language_definitions.json` — second entry: alias `MOJO`,
  `arguments:["lang=mojo"]`, same `/exaudf/exaudfclient`.
- `scripts/lib/script_languages.sh` — generalized entry assembly
  (`script_languages_entry_for`, `_mojo_entry`, `_all_entries`);
  `script_languages_entry` output is byte-identical to before.
- `scripts/install.sh` (+`tests/install-personal-test.sh`) — registers RUST **and**
  MOJO, stripping both aliases idempotently on re-install; new tests, original RUST
  tests unchanged. The SCRIPT_LANGUAGES value gains
  `MOJO=…?lang=mojo#…/exaudf/exaudfclient` alongside the RUST entry.

### 4. Mojo runtime in the image — so a Mojo `.so` can actually load
- `Dockerfile` — builds `exaudfclient` with `--features mojo-bridge`, plus an
  **optional, default-off** `mojo-runtime` donor stage (`--build-arg WITH_MOJO=1`)
  that stages the Mojo runtime libraries into the hermetic rootfs.
- `scripts/install.sh` — `--with-mojo` flag (and `MOJO_VERSION=`) passes the build
  arg through.
- `docs/mojo-runtime.md` **(new)** — how to enable it and how to determine the
  exact runtime library surface from `ldd`.

### Verified vs. unverified
- **Verified here** (toolchain 1.94.1): §1–§3 build + clippy-clean + tests pass
  with the feature **off and on**; `nm -gU` shows all 19 accessors exported;
  default build unchanged; shell unit tests and JSON pass; patch applies clean to
  pristine `main`. Full list in [PATCH.md](PATCH.md).
- **Unverified** (no Docker or Mojo toolchain in this environment): §4's
  `mojo-runtime` Docker stage — its install channel, library globs, and glibc floor
  are best-effort and flagged `VERIFY` in the Dockerfile and
  [docs/mojo-runtime.md](repo/docs/mojo-runtime.md). It is a no-op unless
  `WITH_MOJO=1`, so the default Rust image is unaffected.

### Still outside this patch
The **Mojo SDK + build tool** that emit a conformant, `mojo:`-fingerprinted `.so`
([sdk/](sdk), [tools/](tools)) — design sketches only, pending a real Mojo
toolchain.

## What the host↔.so boundary actually is (extracted, exact)

See [docs/HOST_ABI.md](docs/HOST_ABI.md) for the full reference. In short, to be a
loadable UDF a `.so` must:

1. Export a C symbol **`__exa_udf_entry_<SCRIPT_NAME>`** — `extern "C" fn() -> *const ExaUdfVTable`
   where `<SCRIPT_NAME>` is the SQL script name in UPPER_SNAKE_CASE
   (`loader.rs:36`).
2. Return a pointer to a `#[repr(C)] ExaUdfVTable` (11 fields, `abi.rs`) whose:
   - `abi_version == 7` (`EXA_UDF_ABI_VERSION`), else the host rejects it.
   - `fingerprint` C-string **exactly equals** the host's `EXA_SDK_FINGERPRINT`
     (`"<SDK_VERSION>:<RUSTC_HASH>\0"`), else rejected (`loader.rs:77`).
   - `run: extern "C" fn(ctx: *mut c_void, error_out: *mut *mut c_char) -> i32`.
   - `output_shape: u32` (0 = RETURNS, 1 = EMITS) — validated against the DB's
     iteration type.

Everything on that list is plain C ABI that Mojo can produce today via `@export`
and `abi("C")` — **except one thing**, which is the whole reason a host change is
needed.

## The one blocker → the one required host change

`run`'s `ctx` argument is `*mut c_void`, but it points at a **Rust
`&mut dyn UdfContext` trait object (a fat pointer)** — see the double-indirection
dance in `exasol-udf-macros/src/lib.rs:634`. The UDF is expected to read/write
columns by calling Rust trait methods (`get() -> &Value`, `emit(&[Value])`,
`next()`, `set_return(Option<Value>)`). `Value` is a Rust enum carrying `String`,
a 128-bit `Decimal`, and `chrono` types. **Mojo cannot call Rust trait methods or
construct a Rust enum**, so the opaque `ctx` is useless to it as-is.

Therefore the host must expose the context through **C-ABI accessor functions**.
This is unavoidable and it is the only mandatory host modification. Sketch:
[host/c_ctx.rs](host/c_ctx.rs). These functions take the *same* opaque `ctx`
pointer, undo the double-indirection exactly like the run shim does, call the
trait method, and marshal `Value` into C scalars / `(ptr,len)` strings.

Two smaller host tweaks come along for the ride:

- **Fingerprint check** (`loader.rs:77`) is keyed on the *rustc* hash — a Mojo
  `.so` has none. The fork must accept a namespaced fingerprint for foreign
  languages (e.g. `mojo:<sdk_version>`) or add a `lang` field to the vtable.
- **Symbol visibility:** the Mojo `.so` resolves `exa_ctx_*` from the host, so the
  host must be linked `-rdynamic` (export dynamic symbols), *or* put the accessors
  in a companion `libexa_udf_host.so` that both link against (cleaner).

## What Mojo brings to the table (real capabilities)

- Native AOT codegen; `mojo build --emit shared-lib` produces a `.so`.
- `@export("name")` sets a custom linkage name → we can emit
  `__exa_udf_entry_DOUBLE` exactly.
- `abi("C")` gives C calling convention for the `run` function pointer.
- `sys.ffi.external_call` / `UnsafePointer` let the SDK call the host's `exa_ctx_*`
  accessors and hand back the vtable pointer.

## Open risks (Mojo side)

1. **C struct layout for the vtable.** Mojo does not (yet) guarantee a
   `repr(C)`-equivalent struct layout across FFI. Mitigation in the SDK: build the
   88-byte vtable by writing pointers at hand-computed offsets into a `malloc`'d
   buffer (see [sdk/exasol_udf.mojo](sdk/exasol_udf.mojo), `_build_vtable`), rather
   than trusting a Mojo `struct`'s field order/padding.
2. **No proc-macros.** Rust's `#[exasol_udf]` synthesizes the shim + vtable +
   export symbol. Mojo has compile-time metaprogramming but cannot mint a new
   top-level `@export("__exa_udf_entry_DOUBLE")` symbol from an attribute. So
   either the author writes one `@export` line per UDF, or the build tool
   codegens it. We show the explicit form.
3. **Toolchain packaging & glibc.** The Mojo runtime/stdlib the `.so` links must be
   present in the container image and ABI-compatible with the host's glibc floor
   (`crates/cargo-exasol-udf/slc-glibc-floor.txt`). The patch adds the plumbing for
   this — an optional `mojo-runtime` Dockerfile stage and `install.sh --with-mojo`
   — but its library set is unverified; see [repo/docs/mojo-runtime.md](repo/docs/mojo-runtime.md).
4. **API instability.** Mojo is ~1.0-beta; pin compiler + stdlib.

## Repository layout

Implemented + verified (the host/registration side):

```
mojo-bridge.patch       the whole host + registration change (apply to language-container-rs)
PATCH.md                apply / build / verify guide + what is confirmed
repo/                   language-container-rs checkout with the patch applied (buildable)
repo/docs/mojo-runtime.md   how to bake the Mojo runtime into the SLC image (§4)
```

Design sketches (the Mojo-language side + reference material):

```
docs/HOST_ABI.md        exact extracted contract (symbol, vtable, proto flow)
host/c_ctx.rs           original bridge sketch — superseded by mojo-bridge.patch
sdk/exasol_udf.mojo     Mojo SDK shim: externs, vtable builder, UdfContext, register
examples/double.mojo    scalar RETURNS UDF
examples/sum_positive.mojo   SET RETURNS UDF (group aggregate)
sql/register.sql        CREATE ... MOJO SCALAR/SET SCRIPT registration
tools/mojo-exasol-udf.md  build-tool responsibilities
```

## Build & deploy flow (target UX)

```bash
mojo-exasol-udf build          # mojo build --emit shared-lib + emit entry symbol
exapump bfs upload target/libdouble.so /buckets/bfsdefault/default/udf/libdouble.so
# then run sql/register.sql
```

## Run the native Mojo SLC with Exasol Nano and Podman

> **Experimental:** the native SLC builds and passes its Linux ARM64 protocol
> self-test, but a complete Nano UDF invocation is not yet verified. See
> [Current limitations](#current-limitations) before relying on this for a
> workload.

This section uses the native container in [`native-mojo/`](native-mojo/), not
 the `.so` SDK design described above. It builds a Linux AArch64 executable when
run on an ARM64 host, such as Apple Silicon with Podman's Linux VM.

### 1. Build and unpack the SLC

From the repository root, build the package for the host architecture. The
`selftest` target runs the full ZMQ/protobuf conversation with the bundled fake
Exasol server and must finish with `OK: doubling verified`.

```bash
podman build --arch arm64 \
  -f native-mojo/Dockerfile \
  --target selftest \
  -t mojo-slc:selftest \
  native-mojo
```

Build the package stage, copy the tarball out of the local image, and unpack it:

```bash
podman build --arch arm64 \
  -f native-mojo/Dockerfile \
  --target staging \
  -t mojo-slc:staging \
  native-mojo

container_id="$(podman create mojo-slc:staging)"
podman cp "$container_id:/mojo-slc.tar.gz" ./mojo-slc.tar.gz
podman rm "$container_id"

mkdir -p mojo-rootfs
tar -xzf mojo-slc.tar.gz -C mojo-rootfs
file mojo-rootfs/exaudf/mojoudfclient
```

The final command should identify an ARM64 Linux ELF executable on an ARM64
host. The generated rootfs includes the dynamic loader, the shared-library
closure, and the empty mount points Nano's read-only `nschroot` setup requires.

### 2. Start Nano with the SLC

Nano discovers the language metadata below `/exa/slc`, while it launches UDFs
in `/exa/sandbox`. Mount the same unpacked rootfs at **both** paths. Persist
Nano's database files separately in `nano-exa`.

For a fresh Nano data directory, pass `builtinScriptLanguageName=slc/mojo` at
initialization. The setting is persisted in `nano-exa/exasol.conf`; omit the
`init params=...` suffix on later starts. `--security-opt unmask=ALL` is the
required Podman option for SLC/UDF execution.

```bash
mkdir -p nano-exa

podman run --rm -it --name exanano-mojo \
  --security-opt unmask=ALL \
  --shm-size=512mb \
  --pids-limit=-1 \
  -p 127.0.0.1:8563:8563 \
  -v "$PWD/nano-exa:/exa" \
  -v "$PWD/mojo-rootfs:/exa/slc/mojo:ro" \
  -v "$PWD/mojo-rootfs:/exa/sandbox:ro" \
  docker.io/exasol/nano:latest \
  init params='builtinScriptLanguageName=slc/mojo'
```

Wait for `Database is now up and running!`. The initial local SYS credentials
are `sys` / `exasol` unless changed during initialization. If port 8563 is
occupied, use another host port (for example, `18563:8563`) and use that port
in the connection commands below.

### 3. Register the SQL language alias

Connect as SYS and persist the mapping:

```sql
ALTER SYSTEM SET SCRIPT_LANGUAGES = 'MOJO=builtin_mojo';
```

New sessions can now create Mojo scripts. Confirm that the script is cataloged:

```sql
CREATE SCHEMA IF NOT EXISTS MOJO_TEST;
OPEN SCHEMA MOJO_TEST;

-- DOUBLE is an Exasol type keyword, so it must be quoted.
CREATE OR REPLACE MOJO SCALAR SCRIPT "DOUBLE"(val BIGINT)
RETURNS BIGINT AS
-- The native client dispatches by SQL script name.
/
```

### 4. Execute the baked-in example

The native client contains exactly one UDF at present: `DOUBLE`, taking and
returning `BIGINT`.

```sql
SELECT "DOUBLE"(21);       -- expected result: 42
SELECT "DOUBLE"(-5);       -- expected result: -10
SELECT "DOUBLE"(NULL);     -- expected result: NULL
```

For a local TLS connection using `pyexasol`:

```bash
python3 - <<'PY'
import ssl
import pyexasol

conn = pyexasol.connect(
    dsn='127.0.0.1:8563', user='sys', password='exasol', encryption=True,
    websocket_sslopt={'cert_reqs': ssl.CERT_NONE},
)
conn.execute('OPEN SCHEMA MOJO_TEST')
print(conn.execute('SELECT "DOUBLE"(21)').fetchall())
conn.close()
PY
```

### Current limitations

- **Nano e2e is not green yet.** The `selftest` image verifies the full wire
  protocol against `native-mojo/test/fake_exasol.py`. In the Nano setup above,
  SLC discovery and `CREATE MOJO ... SCRIPT` have been verified, but executing
  the script currently exits as `22002: VM error: Internal error: VM crashed`.
  Treat the SQL execution example as the intended acceptance test and collect
  `nano-exa/logs` when it fails.
- **The UDF is hard coded.** `native-mojo/src/udf.mojo` recognizes only the
  uppercase script name `DOUBLE` and implements only `BIGINT -> BIGINT` scalar
  doubling. Script bodies are ignored. To add a UDF, change the compiled-in
  dispatch and implementation, rebuild the SLC, and restart Nano with the new
  rootfs.
- **Only the native path is runnable here.** `examples/double.mojo`,
  `examples/sum_positive.mojo`, and `sql/register.sql` describe the separate
  dynamic `.so` SDK/Rust-host design; they are not loadable by the native
  `mojoudfclient` yet.
- **No arbitrary Mojo source compilation or dynamic loading exists.** There is
  no `%udf_object` support in the native client and no SET/EMITS implementation.
- **ARM64 is host-specific.** Build with `--arch arm64` only for ARM64 Nano.
  Build a separate image/package for x86_64 Nano; do not mount an ARM64 client
  into an x86_64 database container.
