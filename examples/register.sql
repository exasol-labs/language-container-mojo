-- Registration SQL for the NATIVE Mojo language container.
--
-- The UDFs are baked into the container binary (mojoudfclient) and dispatched by
-- SQL script name — there is NO %udf_object and the script body is ignored.
-- Activate the MOJO language first (see README "Activate the language container"):
--   Nano:       ALTER SYSTEM SET SCRIPT_LANGUAGES = 'MOJO=builtin_mojo';
--   Enterprise: ALTER SYSTEM SET SCRIPT_LANGUAGES =
--     '<existing> MOJO=localzmq+protobuf:///bfsdefault/default/slc/mojoslc?lang=mojo#buckets/bfsdefault/default/slc/mojoslc/exaudf/mojoudfclient';

CREATE SCHEMA IF NOT EXISTS MOJO_TEST;
OPEN SCHEMA MOJO_TEST;

-- SCALAR (map): DOUBLE_MOJO(val) -> 2 * val, NULL -> NULL.
-- Named DOUBLE_MOJO because DOUBLE is a reserved Exasol type keyword.
CREATE OR REPLACE MOJO SCALAR SCRIPT DOUBLE_MOJO(val BIGINT)
RETURNS BIGINT AS
-- native client dispatches by script name; body ignored
/

SELECT DOUBLE_MOJO(21);     -- 42
SELECT DOUBLE_MOJO(-5);     -- -10
SELECT DOUBLE_MOJO(NULL);   -- NULL

-- SET (reduce): SUM_POSITIVE sums the positive values in each group into one row.
CREATE OR REPLACE MOJO SET SCRIPT SUM_POSITIVE(val BIGINT)
RETURNS BIGINT AS
-- native client dispatches by script name; body ignored
/

SELECT SUM_POSITIVE(val) FROM (VALUES 10, 21, -5, 0, 7) t(val);   -- 38

-- Grouped example:
-- SELECT dept, SUM_POSITIVE(amount) FROM sales GROUP BY dept;

-- SCALAR implemented in Python via Mojo's Python interop: imports the bundled
-- module pyudf.transform and calls scale(v) -> v * 10. The CPython runtime and
-- pyudf ship inside the container; add more packages via requirements.txt.
CREATE OR REPLACE MOJO SCALAR SCRIPT PY_SCALE(val BIGINT)
RETURNS BIGINT AS
-- native client dispatches by script name; body ignored
/

SELECT PY_SCALE(val) FROM (VALUES 10, 21, -5, 0, 7) t(val);   -- 100, 210, -50, 0, 70

-- SCALAR EMITS (one-to-many): MIRROR_MOJO emits TWO rows per input row — the
-- value and its negation — so N input rows produce 2*N output rows. Uses EMITS
-- (a result table) instead of RETURNS (a single value).
-- NB: the EMITS column is named RES, not OUT — OUT is a reserved keyword in Exasol.
CREATE OR REPLACE MOJO SCALAR SCRIPT MIRROR_MOJO(val BIGINT)
EMITS (res BIGINT) AS
-- native client dispatches by script name; body ignored
/

SELECT MIRROR_MOJO(val) FROM (VALUES 10, -5, 7) t(val);   -- 10,-10, -5,5, 7,-7
