# examples/triple.mojo — worked example: adding a new native UDF.
#
# Native UDFs are plain Mojo functions in native-mojo/src/udf.mojo, dispatched by
# SQL script name — there is no separate .so, no vtable, no @export. Adding one is
# three small edits to src/udf.mojo (shown below), then rebuild + redeploy the SLC.

# ── 1. The function ─────────────────────────────────────────────────────────
# SCALAR (map): one output row per input row. Takes the group's column as
# (values, nulls) and returns the output column the same way. NULL in -> NULL out.
fn run_triple(values: List[Int64], nulls: List[Bool]) -> (List[Int64], List[Bool]):
    var out = List[Int64]()
    var out_nulls = List[Bool]()
    for i in range(len(values)):
        if nulls[i]:
            out.append(0); out_nulls.append(True)
        else:
            out.append(values[i] * 3); out_nulls.append(False)
    return (out^, out_nulls^)

# ── 2. Add an arm to run_udf() in src/udf.mojo ──────────────────────────────
#   if name == "TRIPLE_MOJO":
#       return run_triple(values, nulls)
#
# ── 3. Add the name to is_known() in src/udf.mojo ───────────────────────────
#   return name == "DOUBLE_MOJO" or name == "SUM_POSITIVE" or name == "TRIPLE_MOJO"
#
# Then rebuild the SLC (see ../native-mojo/build.md), redeploy, and register it:
#
#   CREATE OR REPLACE MOJO SCALAR SCRIPT TRIPLE_MOJO(val BIGINT)
#   RETURNS BIGINT AS
#   -- native client dispatches by script name; body ignored
#   /
#   SELECT TRIPLE_MOJO(14);   -- 42
#
# For a SET (group-reduce) UDF that returns ONE row per group, follow
# run_sum_positive in src/udf.mojo and register with CREATE ... MOJO SET SCRIPT.
