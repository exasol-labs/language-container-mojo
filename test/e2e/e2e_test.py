#!/usr/bin/env python3
"""End-to-end test: run the native Mojo SLC inside a real Exasol database.

Assumes the SLC tarball has already been uploaded and extracted into BucketFS by
the CI workflow (see .github/workflows/e2e.yml). This driver then:

  1. activates the MOJO language (ALTER SYSTEM SET SCRIPT_LANGUAGES),
  2. reconnects and CREATEs the SCALAR / SET / EMITS scripts,
  3. runs real SQL and asserts the results — the true end-to-end path a user
     hits, exercising the same UDFs the offline self-test covers plus a couple
     of datatype conversions through the SQL engine.

Analogue of the Rust SLC's crates/it/tests/db_roundtrip.rs. Exasol's docker-db
images are x86_64-only, so this runs on x86_64 CI only.

Env:
  EXASOL_HOST (localhost)  EXASOL_PORT (8563)
  EXASOL_USER (sys)        EXASOL_PASSWORD (exasol)
  SLC_LANGUAGE_URL         the "MOJO=localzmq+protobuf://...#.../mojoudfclient"
                           alias definition to merge into SCRIPT_LANGUAGES
"""
import os
import ssl
import sys
import time

import pyexasol

HOST = os.environ.get("EXASOL_HOST", "localhost")
PORT = os.environ.get("EXASOL_PORT", "8563")
USER = os.environ.get("EXASOL_USER", "sys")
PASSWORD = os.environ.get("EXASOL_PASSWORD", "exasol")
SLC_LANGUAGE_URL = os.environ["SLC_LANGUAGE_URL"]   # required

SCHEMA = "MOJO_E2E"
NO_TLS = {"cert_reqs": ssl.CERT_NONE}   # docker-db ships a self-signed cert

# The scripts under test (native client dispatches by name; the body is ignored
# but must be present). Mirrors examples/register.sql.
SCRIPTS = {
    "DOUBLE_MOJO":  "CREATE OR REPLACE MOJO SCALAR SCRIPT DOUBLE_MOJO(val BIGINT)\n"
                    "RETURNS BIGINT AS\n-- native client dispatches by name\n",
    "SUM_POSITIVE": "CREATE OR REPLACE MOJO SET SCRIPT SUM_POSITIVE(val BIGINT)\n"
                    "RETURNS BIGINT AS\n-- native client dispatches by name\n",
    "PY_SCALE":     "CREATE OR REPLACE MOJO SCALAR SCRIPT PY_SCALE(val BIGINT)\n"
                    "RETURNS BIGINT AS\n-- native client dispatches by name\n",
    # EMITS column is RES, not OUT — OUT is a reserved keyword in Exasol.
    "MIRROR_MOJO":  "CREATE OR REPLACE MOJO SCALAR SCRIPT MIRROR_MOJO(val BIGINT)\n"
                    "EMITS (res BIGINT) AS\n-- native client dispatches by name\n",
}


def connect():
    return pyexasol.connect(
        dsn=f"{HOST}:{PORT}", user=USER, password=PASSWORD,
        encryption=True, websocket_sslopt=NO_TLS, autocommit=True,
    )


def activate_language():
    """Merge the MOJO alias into SCRIPT_LANGUAGES (idempotent) and reconnect."""
    c = connect()
    row = c.execute(
        "SELECT SYSTEM_VALUE FROM SYS.EXA_PARAMETERS "
        "WHERE PARAMETER_NAME = 'SCRIPT_LANGUAGES'"
    ).fetchone()
    existing = (row[0] if row and row[0] else "").strip()
    # Drop any prior MOJO= alias so re-runs don't stack duplicates.
    kept = " ".join(tok for tok in existing.split() if not tok.startswith("MOJO="))
    merged = (kept + " " + SLC_LANGUAGE_URL).strip()
    print(f"Setting SCRIPT_LANGUAGES to: {merged}")
    c.execute(f"ALTER SYSTEM SET SCRIPT_LANGUAGES='{merged}'")
    c.close()


def as_int(v):
    # Exasol BIGINT/DECIMAL come back through pyexasol as str/Decimal; normalise
    # to a Python int (preserving NULL as None) so value assertions are exact.
    return None if v is None else int(v)


def fetch_scalar(c, sql):
    return as_int(c.execute(sql).fetchone()[0])


def run_checks(c):
    failures = []

    def check(name, got, want):
        if got == want:
            print(f"PASS: {name}: {got!r}")
        else:
            print(f"FAIL: {name}: got {got!r}, expected {want!r}", file=sys.stderr)
            failures.append(name)

    # SCALAR (map) + NULL passthrough
    check("DOUBLE_MOJO(21)", fetch_scalar(c, "SELECT DOUBLE_MOJO(21)"), 42)
    check("DOUBLE_MOJO(-5)", fetch_scalar(c, "SELECT DOUBLE_MOJO(-5)"), -10)
    check("DOUBLE_MOJO(NULL)", fetch_scalar(c, "SELECT DOUBLE_MOJO(CAST(NULL AS BIGINT))"), None)

    # Datatype conversions through the SQL engine: INTEGER and DECIMAL inputs.
    check("DOUBLE_MOJO(INTEGER 21)",
          fetch_scalar(c, "SELECT DOUBLE_MOJO(CAST(21 AS INTEGER))"), 42)
    check("DOUBLE_MOJO(DECIMAL 21)",
          fetch_scalar(c, "SELECT DOUBLE_MOJO(CAST(21 AS DECIMAL(18,0)))"), 42)

    # SET (reduce): one row per group
    check("SUM_POSITIVE group",
          fetch_scalar(c, "SELECT SUM_POSITIVE(val) FROM (VALUES 10,21,-5,0,7) t(val)"),
          38)

    # SCALAR via Python interop
    pyscale = sorted(as_int(r[0]) for r in c.execute(
        "SELECT PY_SCALE(val) FROM (VALUES 10,21,-5,0,7) t(val)").fetchall())
    check("PY_SCALE set", pyscale, sorted([100, 210, -50, 0, 70]))

    # EMITS (one-to-many): 3 input rows -> 6 output rows
    mirror = sorted(as_int(r[0]) for r in c.execute(
        "SELECT MIRROR_MOJO(val) FROM (VALUES 10,-5,7) t(val)").fetchall())
    check("MIRROR_MOJO emits", mirror, sorted([10, -10, -5, 5, 7, -7]))

    return failures


def main():
    activate_language()

    # After ALTER SYSTEM the new alias is visible to fresh sessions. BucketFS may
    # still be extracting the tarball; retry the first CREATE+SELECT until the
    # language container answers (or give up after ~2 min with diagnostics).
    deadline = time.time() + 150
    last_err = None
    while time.time() < deadline:
        try:
            c = connect()
            c.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")
            c.execute(f"OPEN SCHEMA {SCHEMA}")
            for name, ddl in SCRIPTS.items():
                c.execute(ddl)
            # First real UDF call — this is what fails until the SLC is live.
            _ = fetch_scalar(c, "SELECT DOUBLE_MOJO(1)")
            break
        except Exception as e:      # noqa: BLE001 — surface and retry
            last_err = e
            print(f"  ...not ready yet ({type(e).__name__}: {e}); retrying in 10s")
            try:
                c.close()
            except Exception:
                pass
            time.sleep(10)
    else:
        print(f"ERROR: language container never became usable: {last_err}",
              file=sys.stderr)
        sys.exit(2)

    failures = run_checks(c)
    c.close()

    if failures:
        print(f"\n{len(failures)} E2E check(s) FAILED: {', '.join(failures)}",
              file=sys.stderr)
        sys.exit(1)
    print("\n=== ALL E2E CHECKS PASSED ===")


if __name__ == "__main__":
    main()
