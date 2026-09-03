# udf.mojo — the baked-in UDF(s) and name→function dispatch.
#
# For "one function: double" this is trivial. A general container grows the
# dispatch below (match on script_name) or JIT-compiles source_code.

# Apply the UDF to one input batch of a single BIGINT column and return the
# output column (values + null flags), one output row per input row.
#
# `double(val BIGINT) RETURNS BIGINT`: out[i] = 2 * in[i], NULL in → NULL out.
fn run_double(values: List[Int64], nulls: List[Bool]) -> (List[Int64], List[Bool]):
    var out = List[Int64]()
    var out_nulls = List[Bool]()
    for i in range(len(values)):
        if nulls[i]:
            out.append(0); out_nulls.append(True)
        else:
            out.append(values[i] * 2); out_nulls.append(False)
    return (out^, out_nulls^)

# Dispatch on the SQL script name the DB sent in MT_INFO (already UPPER-cased by
# Exasol). Returns True if handled. Extend with more `if name == "..."` arms, or
# default to a single function for a one-UDF container.
fn is_known(name: String) -> Bool:
    return name == "DOUBLE"
