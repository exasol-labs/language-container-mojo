# examples/sum_positive.mojo — SET RETURNS UDF: sum positive values in a group.
#
# SQL:  CREATE ... MOJO SET SCRIPT myschema.sum_positive(val BIGINT) RETURNS BIGINT ...
# Script name SUM_POSITIVE  ->  __exa_udf_entry_SUM_POSITIVE
#
# SET mode: the host makes one run() call per group; the UDF walks the group's
# rows with ctx.next() (the framework has the first row current on entry).

from exasol_udf import UdfContext, build_vtable, SHAPE_RETURNS
from sys.ffi import UnsafePointer, external_call

alias c_char = Int8
alias OpaquePtr = UnsafePointer[NoneType]

fn run_sum_positive(mut ctx: UdfContext) raises:
    var total: Int64 = 0
    while True:
        if not ctx.is_null_i64(0):
            var v = ctx.get_i64(0)
            if v > 0:
                total += v
        if not ctx.next():          # false at the group boundary
            break
    ctx.set_i64(total)              # one output row per group

fn _run(p: OpaquePtr, error_out: UnsafePointer[UnsafePointer[c_char]]) -> Int32:
    var ctx = UdfContext(p)
    try:
        run_sum_positive(ctx)
        return 0
    except e:
        var msg = String(e)
        error_out.store(
            external_call["exa_alloc_cstring", UnsafePointer[c_char]](msg.unsafe_ptr(), len(msg)))
        return 1

fn _destroy() -> None:
    pass

@export("__exa_udf_entry_SUM_POSITIVE")
fn __exa_udf_entry_SUM_POSITIVE() -> OpaquePtr:
    return build_vtable(_run, _destroy, SHAPE_RETURNS)
