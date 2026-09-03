# examples/double.mojo — scalar RETURNS UDF: double a BIGINT.
#
# SQL:  CREATE ... MOJO SCALAR SCRIPT myschema.double(val BIGINT) RETURNS BIGINT ...
# Script name DOUBLE  ->  exported entry symbol  __exa_udf_entry_DOUBLE
#
# Design sketch; approximate Mojo syntax.

from exasol_udf import UdfContext, build_vtable, SHAPE_RETURNS
from sys.ffi import UnsafePointer

alias c_char = Int8
alias OpaquePtr = UnsafePointer[NoneType]

# ---- the author's actual logic ----
fn run_double(mut ctx: UdfContext) raises:
    var x = ctx.get_i64(0)     # column 0, BIGINT -> Int64 (Numeric on the wire)
    ctx.set_i64(x * 2)         # single RETURNS value

# ---- generated glue (build tool emits this; shown explicit for honesty) ----

# C-ABI run shim matching  fn(ctx, error_out) -> i32   (0 ok / 1 user err / 2 panic)
fn _run(p: OpaquePtr, error_out: UnsafePointer[UnsafePointer[c_char]]) -> Int32:
    var ctx = UdfContext(p)
    try:
        run_double(ctx)
        return 0
    except e:
        var msg = String(e)
        error_out.store(
            external_call["exa_alloc_cstring", UnsafePointer[c_char]](msg.unsafe_ptr(), len(msg)))
        return 1

fn _destroy() -> None:
    pass

# The one line only the author (or build tool) can spell: the exact symbol name.
@export("__exa_udf_entry_DOUBLE")
fn __exa_udf_entry_DOUBLE() -> OpaquePtr:
    return build_vtable(_run, _destroy, SHAPE_RETURNS)
