# `mojo-exasol-udf` — build tool responsibilities

Mirrors `cargo-exasol-udf` for the Mojo path. What it must do:

1. **Compile** to a shared object:
   ```bash
   mojo build --emit shared-lib src/double.mojo -o target/libdouble.so
   ```
   Statically link the Mojo stdlib/runtime the `.so` needs, or ensure it is
   present in the container image and within the host's glibc floor
   (`crates/cargo-exasol-udf/slc-glibc-floor.txt`).

2. **Emit the entry glue** so authors don't hand-write it. From an annotation
   (a decorator or a manifest line naming `fn`, SQL name, and shape) generate the
   `_run`/`_destroy` shims and the `@export("__exa_udf_entry_<NAME>")` function.
   The exported symbol name is the only thing that MUST be literal — everything
   else can be templated.

3. **Stamp the vtable correctly**: `abi_version = 7`, `output_shape` from the
   declared RETURNS/EMITS, `fingerprint = "mojo:<sdkver>"` (matching what the
   host fork was patched to accept).

4. **Validate** the produced `.so` before upload (the analogue of
   `cargo-exasol-udf`'s `validate`/`elf` checks):
   - `nm -D libX.so` shows `__exa_udf_entry_<NAME>` (a `T` symbol).
   - Its undefined symbols (`U`) are only the host `exa_ctx_*` / `exa_alloc_cstring`
     accessors (plus libc / Mojo runtime), i.e. nothing unresolvable at load time.
   - No accidental `dlclose`-unsafe TLS destructors, etc.

5. **Scaffold** (`new`) and **upload** helpers wrapping `exapump bfs upload`.

## Host-fork checklist (do these once, in the Rust host)

- Add `host/c_ctx.rs` accessors and export them (`-rdynamic` or companion
  `libexa_udf_host.so`).
- Relax the fingerprint check (`exa-udf-runtime/src/loader.rs:77`) to accept
  `mojo:*` (or add a `lang` byte to the vtable and branch on it).
- Add the `MOJO` language keyword + install script so `CREATE ... MOJO ... SCRIPT`
  and `%udf_object` resolve to this container.
- Bake the Mojo runtime into the container image (`Dockerfile`).
