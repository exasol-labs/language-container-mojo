# double_ext.mojo — TEMPLATE for a dynamically-loaded Mojo UDF (.so).
#
# This is the extension path: instead of baking your UDF into mojoudfclient, you
# compile it to a shared object, upload it to BucketFS, and point a script at it
# with `%udf_object`. mojoudfclient dlopens it at run time (see src/loader.mojo).
#
# Build it (with the SAME Mojo toolchain the container ships — the ABI is
# version-checked but the Mojo runtime must match):
#
#     mojo build --emit shared-lib examples/udf_so/double_ext.mojo -o double_ext.so
#
# Upload double_ext.so to BucketFS, then register a script whose body selects it:
#
#     CREATE OR REPLACE MOJO SCALAR SCRIPT DOUBLE_EXT(val BIGINT) RETURNS BIGINT AS
#     %udf_object /buckets/bfsdefault/default/udfs/double_ext.so
#     /
#
# The exported entry symbol MUST be __exa_udf_entry_<SCRIPT_NAME> — here
# DOUBLE_EXT. See src/loader.mojo for the full C-ABI contract.

from memory import UnsafePointer

alias ABI_VERSION: Int64 = 1


# The host refuses to call a .so whose ABI version does not match its own.
@export
fn __exa_udf_abi_version() -> Int64:
    return ABI_VERSION


# Free the output arrays an entry allocated. Called by the host after it copies
# the results out. Same allocator (one process, one Mojo runtime), so this pairs
# with UnsafePointer.alloc below.
@export
fn __exa_udf_free(vals: UnsafePointer[Int64], nulls: UnsafePointer[Bool]) -> Int64:
    if vals:
        vals.free()
    if nulls:
        nulls.free()
    return 0


# DOUBLE_EXT(val BIGINT) RETURNS BIGINT — SCALAR: out[i] = 2 * in[i], NULL->NULL.
# Reads n_in cells; allocates the output arrays (here the same length as the
# input — a SET UDF would return 1, an EMITS UDF more) and returns the row count.
@export
fn __exa_udf_entry_DOUBLE_EXT(
    in_vals: UnsafePointer[Int64], in_nulls: UnsafePointer[Bool], n_in: Int64,
    out_vals: UnsafePointer[UnsafePointer[Int64]],
    out_nulls: UnsafePointer[UnsafePointer[Bool]],
) -> Int64:
    var n = Int(n_in)
    var cap = n if n > 0 else 1
    var ov = UnsafePointer[Int64].alloc(cap)
    var onull = UnsafePointer[Bool].alloc(cap)
    for i in range(n):
        if in_nulls[i]:
            ov[i] = 0
            onull[i] = True
        else:
            ov[i] = in_vals[i] * 2
            onull[i] = False
    out_vals[0] = ov
    out_nulls[0] = onull
    return Int64(n)
