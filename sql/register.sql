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
