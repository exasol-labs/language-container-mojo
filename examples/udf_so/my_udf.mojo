# my_udf.mojo  (script will be MY_UDF)
#
# A dynamically-loaded UDF shared object (the %udf_object extension path), built
# by following DYNAMIC_UDF.md. It is NOT compiled into mojoudfclient — build it
# separately to a .so and load it from BucketFS:
#
#     docker build --target builder -t mojo-slc-builder .
#     docker run --rm -v "$PWD/examples/udf_so:/work" -w /work mojo-slc-builder \
#         mojo build --emit shared-lib my_udf.mojo -o my_udf.so
#
# then upload my_udf.so to BucketFS and register MY_UDF with %udf_object (see
# DYNAMIC_UDF.md). The exported entry symbol must be __exa_udf_entry_MY_UDF.

from memory import UnsafePointer

alias ABI_VERSION: Int64 = 1

@export
fn __exa_udf_abi_version() -> Int64:
    return ABI_VERSION

@export
fn __exa_udf_free(vals: UnsafePointer[Int64], nulls: UnsafePointer[Bool]) -> Int64:
    if vals: vals.free()
    if nulls: nulls.free()
    return 0

# MY_UDF(val BIGINT) RETURNS BIGINT — one output row per input row.
@export
fn __exa_udf_entry_MY_UDF(
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
            ov[i] = 0; onull[i] = True
        else:
            ov[i] = in_vals[i] * 3      # <-- your logic here
            onull[i] = False
    out_vals[0] = ov
    out_nulls[0] = onull
    return Int64(n)
