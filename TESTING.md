# Testing the native Mojo Script Language Container

The test suite is modelled on the one in
[`exasol-labs/language-container-rs`](https://github.com/exasol-labs/language-container-rs),
adapted to this single-binary, native-Mojo container. It has four layers, from
fastest/most-isolated to closest-to-production, plus the metadata contract:

| Layer | What it proves | Files | How it runs |
|-------|----------------|-------|-------------|
| **Codec unit tests** | The pure protobuf/wire functions (varint, zig-free int reinterpret, packed repeated, length-prefix bounds, decimal parsing, block mapping) are correct in isolation. Analogue of the Rust SLC's per-module `*_tests.rs`. | [`test/mojo/test_codec.mojo`](test/mojo/test_codec.mojo) | `docker build --target unittest` (compiled + run in the Mojo builder image) |
| **Protocol self-test** | The real `mojoudfclient` binary speaks the full ZMQ + protobuf `MT_*` exchange correctly for every UDF/wire combination, including multi-batch group accumulation. | [`test/fake_exasol.py`](test/fake_exasol.py) driven from the Dockerfile `selftest` stage | `docker build --target selftest` |
| **Datatype compatibility** | Every Exasol SQL column type is driven through the real binary and asserted to either convert correctly or be refused with a precise `MT_CLOSE` error — the contract of which SQL types map to a Mojo `Int64`. Part of the `selftest` stage (`--coltype`). | [`test/fake_exasol.py`](test/fake_exasol.py) `run_coltype` matrix | `docker build --target selftest` |
| **Tarball contract** | The shipped SLC rootfs satisfies the sandbox contract: client present/executable and matching the host arch, DT_NEEDED closure fully resolvable through the committed loader search path, bundled CPython staged, sandbox skeleton mount points present, size within a ceiling, and the metadata byte-identical to source. Ported from `dist/tests/slc_tarball_test.sh`. | [`test/slc_tarball_test.sh`](test/slc_tarball_test.sh) | build `--target artifact`, then run the script on the extracted tarball |
| **Language-definitions contract** | The `build_info/language_definitions.json` document conforms to the Exasol v2 metadata schema (aliases `MOJO`, `lang=mojo`, `localzmq+protobuf`, `/exaudf/mojoudfclient`, `deprecation: null`, no legacy keys). One fixture per defect class proves each assertion actually discriminates. Ported from `dist/tests/language_definitions*_test.sh`. | [`test/language_definitions_test.sh`](test/language_definitions_test.sh), [`test/language_definitions_fixtures_test.sh`](test/language_definitions_fixtures_test.sh), [`test/fixtures/language_definitions/`](test/fixtures/language_definitions/) | pure `bash` + `jq` |

Every layer is wired into both CI pipelines
([`.github/workflows/ci.yml`](.github/workflows/ci.yml),
[`.gitlab-ci.yml`](.gitlab-ci.yml)) as its own job, alongside the pre-existing
lint (shellcheck, hadolint, Python syntax) and security (gitleaks, pip-audit)
jobs.

## Running each layer locally

All layers need Docker; the two shell contract tests additionally need `jq` (and
`binutils` for `readelf`), which the commands below provide via a container so
nothing has to be installed on the host.

```bash
# 1. Codec unit tests (Mojo)
docker build -f Dockerfile --target unittest --progress=plain .

# 2. Protocol self-test (full MT_* matrix + multi-batch)
docker build -f Dockerfile --target selftest --progress=plain .

# 3. Tarball contract test
mkdir -p /tmp/lc-out
docker build -f Dockerfile --target artifact --output type=local,dest=/tmp/lc-out .
docker run --rm -v "$PWD:/repo:ro" -v /tmp/lc-out:/art:ro -w /repo debian:trixie-slim bash -c \
  'apt-get update -qq && apt-get install -y -qq --no-install-recommends binutils jq >/dev/null
   bash test/slc_tarball_test.sh /art/mojo-slc.tar.gz'

# 4. Language-definitions contract + fixtures (needs jq on the host, or wrap in a
#    container as above)
bash test/language_definitions_test.sh build_info/language_definitions.json
bash test/language_definitions_fixtures_test.sh
```

## SQL datatype compatibility matrix

`fake_exasol.py --coltype <TYPE>` sends one input column of the given Exasol type
through the real binary (script `DOUBLE_MOJO`, output pinned to BIGINT) and
asserts the container's response. This documents exactly which SQL types the
container converts to a Mojo `Int64` and how it refuses the rest — a refusal is a
clean `MT_CLOSE`, never a crash.

| Exasol type | protobuf `column_type` | wire block | Contract |
|-------------|------------------------|------------|----------|
| `BIGINT` | INT64 | `data_int64` | converted |
| `INTEGER` | INT32 | `data_int32` | converted |
| `DECIMAL`/`NUMERIC` | NUMERIC | `data_string` (decimal text) | converted |
| `DOUBLE` | DOUBLE | `data_double` | refused — `not integer-convertible` |
| `BOOLEAN` | BOOLEAN | `data_bool` | refused — `not integer-convertible` |
| `VARCHAR` | STRING | `data_string` | refused unless the text is an integer literal — non-numeric text → `bad char` |
| `DATE` | DATE | `data_string` | refused — date text → `bad char` |
| `TIMESTAMP` | TIMESTAMP | `data_string` | refused — timestamp text → `bad char` |

`NUMERIC`, `DATE`, `TIMESTAMP`, and `VARCHAR` all arrive in the same
`data_string` block; the container parses it as a decimal integer, so a value
converts only when its text is an integer literal (this is why `DECIMAL` passes
and `DATE`/`TIMESTAMP`/non-numeric `VARCHAR` are refused). Extending real support
for `DOUBLE`/`BOOLEAN`/temporal types would mean widening the codec and a UDF,
then flipping the matching row from *refused* to *converted*.

## Adding a test UDF case

To exercise a new UDF end-to-end, add a mode to `test/fake_exasol.py` that scripts
the group it should receive and the values it should emit, then add a
`run_case ...` line to the `selftest` stage of the [`Dockerfile`](Dockerfile).
The `--splits N` flag already lets any int64 case send its group across several
`MT_NEXT` batches, which exercises the run loop's batch accumulation.

## Deliberately not ported

The Rust SLC bundles exarrow/OpenSSL and ships a much larger surface, so its
tarball test also asserts an OpenSSL trust store, zoneinfo, `nsswitch` modules, a
committed glibc floor, and cargo-generated license bundles. The native Mojo
container has no analogue for those, so those assertions are intentionally
omitted rather than ported as vacuous checks. Its live end-to-end matrix against
real `exasol/docker-db` versions is also out of scope here — this suite verifies
the container against a faithful fake DB and the shipped artifact; the live path
is covered by the deploy instructions in the [`README`](README.md).
