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
