#!/usr/bin/env bash
#
# run-all.sh — run every test layer of the native Mojo SLC in order and print a
# one-line-per-layer summary. Exits non-zero if any layer fails.
#
# All layers use Docker. The tarball layer runs its checks inside a
# debian:trixie-slim container (it needs readelf + jq, which macOS hosts lack);
# the language-definitions layer runs on the host if jq is present, otherwise in
# the same container — so this works on a stock macOS or Linux host with only
# Docker installed.
#
#   bash test/run-all.sh              # run all layers
#   bash test/run-all.sh unit tarball # run only the named layers
#
# Layer names: unit, selftest, contracts, tarball.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
export DOCKER_BUILDKIT=1

results=()

hr() { printf '=%.0s' {1..70}; echo; }

# Build the cached toolbox image (readelf + jq) once, so the shell contract tests
# run offline instead of apt-installing tools inside a throwaway container.
ensure_toolbox() {
    docker build -f Dockerfile --target toolbox -t mojo-slc-toolbox . >/dev/null
}

# --- layers ------------------------------------------------------------------

layer_unit() {
    docker build -f Dockerfile --target unittest --progress=plain .
}

layer_selftest() {
    docker build -f Dockerfile --target selftest --progress=plain .
}

layer_contracts() {
    if command -v jq >/dev/null 2>&1; then
        bash test/language_definitions_test.sh build_info/language_definitions.json \
            && bash test/language_definitions_fixtures_test.sh
    else
        ensure_toolbox || return 1
        docker run --rm -v "$ROOT:/w" -w /w mojo-slc-toolbox bash -c '
            bash test/language_definitions_test.sh build_info/language_definitions.json
            bash test/language_definitions_fixtures_test.sh'
    fi
}

layer_tarball() {
    local out rc
    ensure_toolbox || return 1
    out="$(mktemp -d)"
    if docker build -f Dockerfile --target artifact --output "type=local,dest=$out" .; then
        docker run --rm -v "$ROOT:/repo:ro" -v "$out:/art:ro" -w /repo mojo-slc-toolbox \
            bash -c 'bash test/slc_tarball_test.sh /art/mojo-slc.tar.gz'
        rc=$?
    else
        rc=1
    fi
    rm -rf "$out"
    return $rc
}

# --- runner ------------------------------------------------------------------

run_layer() {
    local key="$1" name="$2" fn="$3"
    echo; hr; echo ">>> $name"; hr
    if "$fn"; then
        results+=("PASS|$name")
    else
        results+=("FAIL|$name")
    fi
}

# Selection: no args = all layers, in this order.
select_all=(unit selftest contracts tarball)
if [[ $# -gt 0 ]]; then
    selected=("$@")
else
    selected=("${select_all[@]}")
fi

for key in "${selected[@]}"; do
    case "$key" in
        unit)      run_layer unit      "Unit tests (Mojo codec)"                 layer_unit ;;
        selftest)  run_layer selftest  "Protocol self-test + SQL datatype matrix" layer_selftest ;;
        contracts) run_layer contracts "Language-definitions contract + fixtures" layer_contracts ;;
        tarball)   run_layer tarball   "SLC tarball contract"                    layer_tarball ;;
        *) echo "unknown layer '$key' (known: ${select_all[*]})" >&2; exit 2 ;;
    esac
done

echo; hr; echo "SUMMARY"; hr
fails=0
for r in "${results[@]}"; do
    st="${r%%|*}"; nm="${r#*|}"
    printf '  %-4s  %s\n' "$st" "$nm"
    [[ "$st" == FAIL ]] && fails=$((fails + 1))
done
echo
if [[ "$fails" -gt 0 ]]; then
    echo "$fails test layer(s) FAILED"
    exit 1
fi
echo "All test layers passed."
