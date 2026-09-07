# udf.mojo — the baked-in UDF(s) and name→function dispatch.
#
# Native-container UDFs are plain Mojo functions over a group's decoded column,
# not `.so` entry points: no vtable, no @export, no UdfContext. Each takes the
# group's (values, nulls) and returns the output column (values, nulls). The run
# loop in main.mojo collects a whole group, calls `run_udf`, and emits the result
# — so a SCALAR UDF returns one row per input row (a map), and a SET UDF returns
# one row per group (a reduce).

from python import Python

# double_mojo(val BIGINT) RETURNS BIGINT — SCALAR: out[i] = 2 * in[i], NULL -> NULL.
fn run_double_mojo(values: List[Int64], nulls: List[Bool]) -> (List[Int64], List[Bool]):
    var out = List[Int64]()
    var out_nulls = List[Bool]()
    for i in range(len(values)):
        if nulls[i]:
            out.append(0); out_nulls.append(True)
        else:
            out.append(values[i] * 2); out_nulls.append(False)
    return (out^, out_nulls^)

# sum_positive(val BIGINT) RETURNS BIGINT — SET: sum the positive values in the
# group into a single output row (NULLs and non-positives ignored). Mirrors the
# `.so` SDK example's `run_sum_positive`, adapted to the native model.
fn run_sum_positive(values: List[Int64], nulls: List[Bool]) -> (List[Int64], List[Bool]):
    var total: Int64 = 0
    for i in range(len(values)):
        if not nulls[i] and values[i] > 0:
            total += values[i]
    var out = List[Int64]()
    var out_nulls = List[Bool]()
    out.append(total)          # exactly one output row per group
    out_nulls.append(False)
    return (out^, out_nulls^)

# py_scale(val BIGINT) RETURNS BIGINT — SCALAR, implemented in Python via interop:
# imports the bundled dotted module `pyudf.transform` and calls its `scale()`.
# Shows `from python import Python` + `Python.import_module("x.y")`; extend by
# importing any package staged into /opt/pypkgs (see requirements.txt). `raises`
# because Python import/call can fail (e.g. a missing package).
fn run_py_scale(values: List[Int64], nulls: List[Bool]) raises -> (List[Int64], List[Bool]):
    var transform = Python.import_module("pyudf.transform")   # dotted import
    var out = List[Int64]()
    var out_nulls = List[Bool]()
    for i in range(len(values)):
        if nulls[i]:
            out.append(0); out_nulls.append(True)
        else:
            var r = transform.scale(values[i])   # call the Python function
            out.append(Int(r)); out_nulls.append(False)
    return (out^, out_nulls^)

# Dispatch on the SQL script name the DB sent in MT_INFO (already UPPER-cased by
# Exasol). `raises` because a Python-backed UDF may raise.
fn run_udf(name: String, values: List[Int64], nulls: List[Bool]) raises -> (List[Int64], List[Bool]):
    if name == "SUM_POSITIVE":
        return run_sum_positive(values, nulls)
    if name == "PY_SCALE":
        return run_py_scale(values, nulls)
    return run_double_mojo(values, nulls)   # DOUBLE_MOJO (default)

fn is_known(name: String) -> Bool:
    return name == "DOUBLE_MOJO" or name == "SUM_POSITIVE" or name == "PY_SCALE"
