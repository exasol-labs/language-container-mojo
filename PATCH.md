# `mojo-bridge.patch` — the C-ABI context bridge, as a buildable patch

`mojo-bridge.patch` is the real, compiled version of the earlier
[host/c_ctx.rs](host/c_ctx.rs) sketch, wired into `language-container-rs` and
verified against toolchain **1.94.1** (the repo's pinned channel).

## What it changes (15 files, +837 / -27 lines)

**Host bridge + load path (Rust):**

| file | change |
|------|--------|
| `crates/exa-udf-runtime/src/c_ctx.rs` | **new** — 19 `extern "C"` accessors (`exa_ctx_*`, `exa_alloc_cstring`), a thread-local multi-column emit-row buffer, a GC `anchor()`, and unit tests |
| `crates/exa-udf-runtime/src/lib.rs` | `#[cfg(feature="mojo-bridge")] pub mod c_ctx;` |
| `crates/exa-udf-runtime/src/loader.rs` | extracts `validate_fingerprint`; under `mojo-bridge`, a `"mojo:<ver>"` fingerprint waives the rustc-hash equality (the `abi_version==7` check remains the structural guard). Default (feature off) stays exact-match |
| `crates/exa-udf-runtime/src/loader_tests.rs` | fingerprint tests (exact-match, Rust mismatch reject; +mojo accept / unknown-lang reject under the feature) |
| `crates/exa-udf-runtime/Cargo.toml` | adds the off-by-default `mojo-bridge` feature |
| `crates/exaudfclient/Cargo.toml` | forwards a `mojo-bridge` feature to the runtime |
| `crates/exaudfclient/build.rs` | **new** — emits `-rdynamic` (Linux) / `-export_dynamic` (macOS) under the feature |
| `crates/exaudfclient/src/main.rs` | `c_ctx::anchor()` under the feature; `is_supported_lang` accepts `lang=mojo` when the feature is on (`lang=rust` always; others never) |
| `crates/exaudfclient/src/main_tests.rs` | `language_gate` test (rust always / python never / mojo iff feature) |

**`MOJO` language keyword + registration (build + shell):**

| file | change |
|------|--------|
| `build_info/language_definitions.json` | adds a second language entry: alias `MOJO`, `arguments:["lang=mojo"]`, same `/exaudf/exaudfclient` executable |
| `Dockerfile` | builds `exaudfclient` with `--features mojo-bridge`; adds an **optional, default-off** `mojo-runtime` donor stage (`--build-arg WITH_MOJO=1`) that stages the Mojo runtime libraries into the hermetic rootfs |
| `scripts/lib/script_languages.sh` | generalizes entry assembly (`script_languages_entry_for`); adds `script_languages_mojo_entry` and `script_languages_all_entries` (RUST + MOJO). `script_languages_entry` output is byte-identical to before |
| `scripts/install.sh` | `script_languages_with_slc_entries` strips **both** managed aliases idempotently; both transports now register RUST **and** MOJO; adds `--with-mojo` (+`MOJO_VERSION=`) to pass `WITH_MOJO=1` through to the image build |
| `scripts/tests/install-personal-test.sh` | adds MOJO-entry and combined-strip assertions; the original RUST assertions are unchanged and still pass |
| `docs/mojo-runtime.md` | **new** — how to build with `--with-mojo` and how to determine the exact Mojo runtime library surface from `ldd` |

> **Not verified here:** the `mojo-runtime` Docker stage (install channel, library
> globs, glibc floor) — no Docker or Mojo toolchain in this environment. It is
> flagged `VERIFY` inline and is a **no-op unless `WITH_MOJO=1`**, so the default
> Rust image is unchanged. Everything else below is verified.

### How `MOJO` works

One container, two aliases. The registration string gains a second entry that
points at the *same* `exaudf/exaudfclient` but with `?lang=mojo`:

```
RUST=localzmq+protobuf:///<svc>/<bucket>/<slc>?lang=rust#buckets/<svc>/<bucket>/<slc>/exaudf/exaudfclient
MOJO=localzmq+protobuf:///<svc>/<bucket>/<slc>?lang=mojo#buckets/<svc>/<bucket>/<slc>/exaudf/exaudfclient
```

`CREATE MOJO SCALAR SCRIPT …` launches `exaudfclient <endpoint> lang=mojo`, which
the feature-built client accepts, then `dlopen`s a `mojo:`-fingerprinted `.so`
through the C-ABI bridge. RUST is completely unaffected.

The bridge undoes the host's double-indirection exactly as
`dispatch::invoke_run` erases it (`*(p as *mut &mut dyn UdfContext)`), then calls
the real `UdfContext` trait methods — so it tracks the SDK's own types, not a
copy.

## Apply & build

```bash
git clone https://github.com/exasol-labs/language-container-rs
cd language-container-rs
git apply /path/to/mojo-bridge.patch

cargo build   -p exa-udf-runtime --features mojo-bridge      # library
cargo clippy  -p exa-udf-runtime --features mojo-bridge      # lint-clean
cargo test    -p exa-udf-runtime --features mojo-bridge --lib   # incl. c_ctx tests
cargo build   -p exaudfclient   --features mojo-bridge      # final host binary
```

## Verified here

- `git apply --check` clean against a pristine `main`, then a clean build.
- `exa-udf-runtime` builds + clippy-clean both ways. Lib tests: **65 pass with
  the feature off, 68 with it on** (adds the emit-buffer test and the two
  feature-gated fingerprint tests).
- Fingerprint behaviour is guarded: feature **off** still rejects any non-exact
  fingerprint (Rust `.so` with a mismatched rustc hash included); feature **on**
  accepts `"mojo:<ver>"` but still rejects unknown tags (`python:3.12`) and
  Rust-shaped mismatches.
- `exaudfclient --features mojo-bridge` links, and `nm -gU` shows **all 19**
  `exa_ctx_* / exa_alloc_cstring` symbols in the binary's dynamic symbol table.
- The **default** build (feature off) exports **0** of them and keeps the exact
  fingerprint rule — the change is non-invasive.
- `exaudfclient` tests pass with the feature off **and** on; `language_gate`
  confirms `lang=mojo` is accepted only under the feature.
- `bash -n` clean on `install.sh` + the lib; `language_definitions.json` parses
  and lists aliases `RUST`, `MOJO`; **all** `install-personal-test.sh`
  assertions pass — the original RUST ones unchanged, plus the new MOJO-entry and
  both-alias idempotent-strip checks.

## Still to do beyond this patch (unchanged from the design)

This patch delivers the entire **host + registration** side: the C-ABI bridge,
the fingerprint relaxation, the `lang=mojo` acceptance, the `MOJO` keyword, the
install-script registration, and the **plumbing** to bake the Mojo runtime into
the image (`--with-mojo` / the `mojo-runtime` Dockerfile stage — unverified, see
above). What remains is the **Mojo SDK + build tool** that emit a conformant,
`mojo:`-fingerprinted `.so` ([sdk/](sdk), [tools/](tools)), plus verifying the
runtime stage against a real Mojo toolchain. See [README.md](README.md).
