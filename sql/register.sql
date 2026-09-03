-- Registration SQL. Assumes a MOJO script language has been installed as an SLC
-- (the fork's scripts/install.sh equivalent), so `%udf_object` is honored and
-- the CREATE ... MOJO ... form is accepted.

-- Scalar RETURNS. Script name DOUBLE must match the exported symbol
-- __exa_udf_entry_DOUBLE (loader builds the symbol from the SQL name, verbatim,
-- UPPER_SNAKE_CASE).
-- DOUBLE is an Exasol type keyword, so quote the baked-in script name.
CREATE OR REPLACE MOJO SCALAR SCRIPT myschema."DOUBLE"(val BIGINT)
RETURNS BIGINT AS
%udf_object /buckets/bfsdefault/default/udf/libdouble.so;
/

SELECT myschema."DOUBLE"(21);        -- -> 42

-- SET RETURNS group aggregate. Script name SUM_POSITIVE -> __exa_udf_entry_SUM_POSITIVE
CREATE OR REPLACE MOJO SET SCRIPT myschema.sum_positive(val BIGINT)
RETURNS BIGINT AS
%udf_object /buckets/bfsdefault/default/udf/libsum_positive.so;
/

SELECT dept, myschema.sum_positive(amount)
FROM   sales
GROUP  BY dept;
