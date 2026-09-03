# sdk/exasol_udf.mojo — Mojo SDK shim for Exasol UDFs (design sketch).
#
# APPROXIMATE Mojo 1.0 syntax. Verify against your pinned compiler; the exact
# spellings of external_call, function-pointer types, @export, and global/static
# initialization are the parts most likely to drift. What is load-bearing (and
# extracted from the Rust host, not invented) are the SYMBOL NAMES, the vtable
# BYTE LAYOUT, and the C signatures — those must match exactly.

from sys.ffi import external_call, UnsafePointer
from memory import memset_zero

alias c_void   = NoneType
alias c_char   = Int8
alias OpaquePtr = UnsafePointer[c_void]

alias ABI_VERSION: UInt32 = 7          # must equal host EXA_UDF_ABI_VERSION
alias SHAPE_RETURNS: UInt32 = 0
alias SHAPE_EMITS:   UInt32 = 1

# Host fork must accept this namespaced fingerprint for non-Rust .so files
# (the stock host compares against "<sdkver>:<rustc_hash>"; a Mojo .so has no
# rustc hash). Coordinate the exact string with the host patch.
alias FINGERPRINT = "mojo:0.1.0\0"

# --------------------------------------------------------------------------
# Host accessor externs (resolved from the host binary / libexa_udf_host.so).
# Signatures mirror host/c_ctx.rs one-for-one.
# --------------------------------------------------------------------------

struct UdfContext:
    """Thin wrapper over the opaque host ctx pointer. Methods call exa_ctx_*."""
    var _p: OpaquePtr

    fn __init__(out self, p: OpaquePtr):
        self._p = p

    fn num_columns(self) -> Int:
        return external_call["exa_ctx_num_columns", Int](self._p)

    fn get_i64(self, col: Int) raises -> Int64:
        var out: Int64 = 0
        var is_null: Int32 = 0
        var rc = external_call["exa_ctx_get_i64", Int32](
            self._p, col, UnsafePointer.address_of(out), UnsafePointer.address_of(is_null))
        if rc != 0: raise Error("get_i64: type error at col " + String(col))
        if is_null != 0: raise Error("get_i64: unexpected NULL at col " + String(col))
        return out

    fn get_f64(self, col: Int) raises -> Float64:
        var out: Float64 = 0
        var is_null: Int32 = 0
        var rc = external_call["exa_ctx_get_f64", Int32](
            self._p, col, UnsafePointer.address_of(out), UnsafePointer.address_of(is_null))
        if rc != 0: raise Error("get_f64: type error")
        if is_null != 0: raise Error("get_f64: unexpected NULL")
        return out

    fn is_null_i64(self, col: Int) -> Bool:
        var out: Int64 = 0
        var is_null: Int32 = 0
        _ = external_call["exa_ctx_get_i64", Int32](
            self._p, col, UnsafePointer.address_of(out), UnsafePointer.address_of(is_null))
        return is_null != 0

    fn get_string(self, col: Int) raises -> String:
        var ptr = OpaquePtr()
        var length: Int = 0
        var is_null: Int32 = 0
        var rc = external_call["exa_ctx_get_string", Int32](
            self._p, col,
            UnsafePointer.address_of(ptr), UnsafePointer.address_of(length),
            UnsafePointer.address_of(is_null))
        if rc != 0: raise Error("get_string: type error")
        if is_null != 0: raise Error("get_string: unexpected NULL")
        # Copy immediately — the borrow is valid only until the next accessor call.
        return String(ptr.bitcast[c_char](), length)   # (constructor shape approximate)

    fn next(mut self) raises -> Bool:
        var has: Int32 = 0
        var rc = external_call["exa_ctx_next", Int32](self._p, UnsafePointer.address_of(has))
        if rc != 0: raise Error("next(): not a SET-mode context")
        return has != 0

    # --- output (RETURNS shape) ---
    fn set_i64(mut self, v: Int64):
        _ = external_call["exa_ctx_set_return_i64", Int32](self._p, v)

    fn set_f64(mut self, v: Float64):
        _ = external_call["exa_ctx_set_return_f64", Int32](self._p, v)

    fn set_string(mut self, v: String):
        _ = external_call["exa_ctx_set_return_string", Int32](
            self._p, v.unsafe_ptr(), len(v))

    fn set_null(mut self):
        _ = external_call["exa_ctx_set_return_null", Int32](self._p)

    # --- output (EMITS shape) ---
    fn emit_i64(mut self, v: Int64):
        _ = external_call["exa_ctx_emit_i64", Int32](self._p, v)

# --------------------------------------------------------------------------
# Vtable construction. Built by hand at fixed offsets rather than as a Mojo
# struct, so we do not depend on Mojo guaranteeing repr(C) layout. 88 bytes,
# LP64. Offsets from docs/HOST_ABI.md.
# --------------------------------------------------------------------------

alias VTABLE_SIZE = 88
# Byte offsets:
#  0 abi_version(u32) | 8 fingerprint(ptr) | 16 run(ptr) | 24 destroy(ptr)
# 32 default_output_columns | 40 vs_adapter | 48 gen_import | 56 gen_export
# 64 annotated_input | 72 annotated_output | 80 output_shape(u32)

# The C-ABI run function pointer type the host expects.
alias RunFn = fn(OpaquePtr, UnsafePointer[UnsafePointer[c_char]]) -> Int32
alias DestroyFn = fn() -> None

fn _put_ptr(base: OpaquePtr, offset: Int, value: OpaquePtr):
    (base.bitcast[OpaquePtr]() + (offset // 8)).store(value)

fn _put_u32(base: OpaquePtr, offset: Int, value: UInt32):
    (base.bitcast[UInt32]() + (offset // 4)).store(value)

fn build_vtable(run: RunFn, destroy: DestroyFn, shape: UInt32) -> OpaquePtr:
    """Allocate + populate the 88-byte vtable. Returned pointer must stay alive
    for the process lifetime (host holds it for the whole session)."""
    var v = external_call["malloc", OpaquePtr](VTABLE_SIZE)
    memset_zero(v.bitcast[Int8](), VTABLE_SIZE)   # nulls out all Option<fn>/schema ptrs
    _put_u32(v, 0, ABI_VERSION)
    _put_ptr(v, 8, _fingerprint_ptr())
    _put_ptr(v, 16, __get_address_of(run))        # fn->ptr cast (approx; see note)
    _put_ptr(v, 24, __get_address_of(destroy))
    _put_u32(v, 80, shape)
    return v

fn _fingerprint_ptr() -> OpaquePtr:
    # A static, NUL-terminated copy of FINGERPRINT living in .rodata.
    return FINGERPRINT.unsafe_ptr().bitcast[c_void]()

# NOTE: taking the address of a Mojo `fn` as a raw C function pointer is the
# sharpest syntactic unknown here. If Mojo will not hand back a plain code
# pointer, the fallback is to write the `run`/`destroy` shims in a 3-line C file
# compiled alongside, export them, and have build_vtable() resolve them by name
# with external_call["&symbol"] — mechanical, no Mojo-language risk.
