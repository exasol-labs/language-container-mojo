# py_udf.mojo  (script will be PY_UDF)  — HYBRID Mojo + Python example.
#
# A dynamically-loaded UDF .so (the %udf_object extension path) whose logic runs
# in Python via Mojo's interop: `from python import Python`. It bundles NO Python
# itself — it reuses the CPython runtime already inside the container (the host's
# setup_python_env() points MOJO_PYTHON_LIBRARY at /exaudf/libpython.so before it
# ever loads a .so, so import_module works from here).
#
# Build + deploy exactly like any .so UDF (see DYNAMIC_UDF.md):
#     docker run --rm -v "$PWD/examples/udf_so:/work" -w /work mojo-slc-builder \
#         mojo build --emit shared-lib py_udf.mojo -o py_udf.so
# then upload py_udf.so to BucketFS and register PY_UDF with %udf_object.
#
# The exported entry symbol must be __exa_udf_entry_PY_UDF.

from python import Python
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

# PY_UDF(val BIGINT) RETURNS BIGINT — integer square root of |val|, computed by
# Python's math.isqrt. NULL -> NULL. Shows a real `Python.import_module` call and
# a Python function invocation from inside a dynamically-loaded UDF.
#
# The C entry cannot raise (it is a plain C symbol), so the Python work is wrapped
# in try/except: on any Python-side failure it frees its buffers and returns -1,
# which the host turns into a clean MT_CLOSE.
@export
fn __exa_udf_entry_PY_UDF(
    in_vals: UnsafePointer[Int64], in_nulls: UnsafePointer[Bool], n_in: Int64,
    out_vals: UnsafePointer[UnsafePointer[Int64]],
    out_nulls: UnsafePointer[UnsafePointer[Bool]],
) -> Int64:
    var n = Int(n_in)
    var cap = n if n > 0 else 1
    var ov = UnsafePointer[Int64].alloc(cap)
    var onull = UnsafePointer[Bool].alloc(cap)
    try:
        var math = Python.import_module("math")     # <-- Python from Mojo
        for i in range(n):
            if in_nulls[i]:
                ov[i] = 0; onull[i] = True
            else:
                var v = in_vals[i]
                var a = v if v >= 0 else -v          # |val|
                var r = math.isqrt(a)               # call the Python function
                ov[i] = Int64(Int(r)); onull[i] = False
        out_vals[0] = ov
        out_nulls[0] = onull
        return Int64(n)
    except:
        ov.free(); onull.free()
        return -1
