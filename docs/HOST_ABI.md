# Host ↔ `.so` ABI — extracted reference

Verbatim from `exasol-labs/language-container-rs@main`. This is what any `.so`
(Rust or Mojo) must satisfy to be loaded by the `exaudfclient` host.

## 1. Entry symbol (`crates/exa-udf-runtime/src/loader.rs`)

```rust
type EntryFn = unsafe extern "C" fn() -> *const ExaUdfVTable;
// host resolves:  __exa_udf_entry_<SCRIPT_NAME>       // loader.rs:36
```
- `<SCRIPT_NAME>` = the SQL object name from the handshake metadata, verbatim,
  already UPPER_SNAKE_CASE. A plain Rust `fn run` → `__exa_udf_entry_RUN`.
  `#[exasol_udf(name = "FOO")]` → `__exa_udf_entry_FOO`.
- Host calls the entry fn, gets the vtable pointer, then validates
  `abi_version` and `fingerprint` **before** ever calling `run` (loader.rs:53-87).

## 2. The vtable (`crates/exasol-udf-sdk/src/abi.rs`)

`EXA_UDF_ABI_VERSION = 7`. `#[repr(C)]`, so field order + C padding are the
contract. On x86-64/aarch64 LP64 the layout is:

| off | field | type | notes |
|----:|-------|------|-------|
| 0  | `abi_version` | `u32` | must be 7 |
| 8  | `fingerprint` | `*const c_char` | NUL-term `"<SDK_VER>:<RUSTC_HASH>"`; must equal host's |
| 16 | `run` | `extern "C" fn(*mut c_void, *mut *mut c_char) -> i32` | 0=ok, 1=user err, 2=panic |
| 24 | `destroy` | `extern "C" fn()` | no-op for stateless |
| 32 | `default_output_columns` | `Option<fn(*mut *mut c_char) -> i32>` | nullable ptr |
| 40 | `virtual_schema_adapter_call` | `Option<fn(*mut c_void, *const c_char, *mut *mut c_char) -> i32>` | nullable |
| 48 | `generate_sql_for_import_spec` | `Option<fn(*const c_char, *mut *mut c_char) -> i32>` | nullable |
| 56 | `generate_sql_for_export_spec` | `Option<fn(*const c_char, *mut *mut c_char) -> i32>` | nullable |
| 64 | `annotated_input_schema` | `*const c_char` | JSON or NULL |
| 72 | `annotated_output_schema` | `*const c_char` | JSON or NULL |
| 80 | `output_shape` | `u32` (`repr(u32)`) | 0=Returns, 1=Emits |

Total size 88 bytes (trailing pad to 8). `Option<extern "C" fn>` is
null-pointer-optimized, i.e. it is exactly a nullable function pointer — store 0
for "not implemented".

### `run`'s `ctx` — the non-C part

`ctx: *mut c_void` is double-indirected: the host builds
`let mut r: &mut dyn UdfContext = &mut bridge; run(&mut r as *mut _ as *mut c_void, ...)`.
The Rust shim restores it via `&mut *(ctx as *mut &mut dyn UdfContext)`
(`exasol-udf-macros/src/lib.rs:634`). A non-Rust `.so` cannot use this pointer
directly — hence the C accessor bridge in `host/c_ctx.rs`.

### `error_out`

On the `1` (user-error) path the `.so` may write a `malloc`'d, NUL-terminated C
string to `*error_out`; the host takes ownership and `free`s it. Allocation
crosses the boundary through the **C allocator only** (never Rust's), because the
`.so` statically links its own Rust runtime. Mojo must likewise `malloc` the
error string (or call a host-provided `exa_alloc_cstring`).

## 3. `UdfContext` trait surface (`crates/exasol-udf-sdk/src/context.rs`)

What the C accessor bridge must cover (the methods a UDF actually uses):

```
num_columns() -> usize
get(col) -> &Value                       // typed getters derive from this:
get_i64/get_f64/get_bool/get_string/get_decimal/get_date/get_timestamp -> Option<T>
next() -> bool                           // SET input only; false at group boundary
emit(&[Value])                           // EMITS output
set_return(Option<Value>)                // RETURNS output (single value)
```

`Value` enum: `Null | Double(f64) | Int32(i32) | Int64(i64) | Numeric(Decimal) |
Bool(bool) | String(String) | Date(NaiveDate) | Timestamp(NaiveDateTime)`.
`Decimal { unscaled: i128, scale: u8 }`.

## 4. Wire protocol (host-owned; Mojo never sees it)

`crates/exa-proto/proto/zmqcontainer.proto`, `MessageType`:

```
MT_CLIENT=1 MT_INFO=2 MT_META=3 MT_CLOSE=4 MT_IMPORT=5 MT_NEXT=6 MT_RESET=7
MT_EMIT=8 MT_RUN=9 MT_DONE=10 MT_CLEANUP=11 MT_FINISHED=12 MT_PING_PONG=13
MT_TRY_AGAIN=14 MT_CALL=15 MT_RETURN=16 MT_UNDEFINED_CALL=17
```

Lifecycle: `MT_CLIENT`→`MT_INFO`, `MT_META`→types, then per group
`MT_RUN` / loop(`MT_NEXT` pull, `MT_EMIT` push) / `MT_DONE`, then
`MT_CLEANUP`/`MT_FINISHED`. The host drives all of this over a ZMQ **REQ** socket
given as a CLI arg. **This entire layer is reused; the Mojo `.so` is invoked only
through the vtable `run`.**
