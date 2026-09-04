# udf.mojo — the baked-in UDF(s) and name→function dispatch.
#
# Native-container UDFs are plain Mojo functions over a group's decoded column,
# not `.so` entry points: no vtable, no @export, no UdfContext. Each takes the
# group's (values, nulls) and returns the output column (values, nulls). The run
# loop in main.mojo collects a whole group, calls `run_udf`, and emits the result
# — so a SCALAR UDF returns one row per input row (a map), and a SET UDF returns
# one row per group (a reduce).

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

# Dispatch on the SQL script name the DB sent in MT_INFO (already UPPER-cased by
# Exasol). Add an arm per baked-in UDF.
fn run_udf(name: String, values: List[Int64], nulls: List[Bool]) -> (List[Int64], List[Bool]):
    if name == "SUM_POSITIVE":
        return run_sum_positive(values, nulls)
    return run_double_mojo(values, nulls)   # DOUBLE (default)

fn is_known(name: String) -> Bool:
    return name == "DOUBLE_MOJO" or name == "SUM_POSITIVE"
