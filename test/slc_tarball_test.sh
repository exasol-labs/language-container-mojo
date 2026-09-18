#!/usr/bin/env bash
#
# slc_tarball_test.sh — contract assertions over the shipped SLC artifact
# tarball produced by `docker build --target artifact`. The extracted tree is
# the UDF's entire root filesystem inside the Exasol sandbox, so every assertion
# here states something a Mojo UDF may rely on at runtime.
#
# Architecture-dependent facts (multiarch triplet, loader path, ELF machine)
# are derived from the runner and from the tree itself, never hardcoded, so the
# same script asserts the correct contract on x86_64 and aarch64.
#
# Ported from exasol-labs/language-container-rs (dist/tests/slc_tarball_test.sh)
# and adapted to the native Mojo container:
#   * client is exaudf/mojoudfclient (not exaudfclient)
#   * the tree is NOT usr-merged — the Dockerfile stages every shared object at
#     its real absolute path and registers each .so directory in
#     etc/ld.so.conf.d/mojo.conf, so the DT_NEEDED closure is resolved through
#     that committed loader-search path, not through /lib->/usr/lib symlinks.
#   * bundled CPython is part of the contract (exaudf/libpython.so + the stdlib
#     + opt/pypkgs), because src/main.mojo points MOJO_PYTHON_LIBRARY at it.
# Rust-specific surface with no Mojo analogue (OpenSSL trust store, zoneinfo,
# nsswitch, glibc floor, cargo license bundles) is deliberately not ported.
#
# Run: bash test/slc_tarball_test.sh <tarball>
set -uo pipefail

CLIENT_REL="exaudf/mojoudfclient"

# Paths that must never ship inside the sandbox rootfs.
FORBIDDEN_PAYLOAD_PATHS=(
    bin/sh
    usr/bin/apt
    usr/bin/dpkg
    usr/bin/dpkg-deb
)

# Mount-point directories the Exasol sandbox bind-mounts over. They must exist
# in the shipped tree (nschroot mounts onto them) and hold no payload.
SKELETON_DIRS=(
    proc
    sys
    dev
    buckets
    run/secrets
    var/tmp
)

MAX_SYMLINK_HOPS=16

# Measured ~135 MB on aarch64 (2026-09), dominated by the CPython stdlib +
# libpython + the Mojo runtime closure. The ceiling exists to catch a
# regression that bundles a heavy pip package or the full Mojo SDK by accident;
# the measured value is printed on every run so ordinary drift stays visible.
STAGED_TREE_CEILING_BYTES=220000000

failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
pass() { echo "PASS: $1"; }
die()  { echo "ERROR: $1" >&2; exit 2; }

# --- tree helpers ------------------------------------------------------------

declare -A TREE_PATH_BY_BASENAME=()
declare -A SONAME_OF_FILE=()
declare -A NEEDED_OF_FILE=()
declare -a STAGED_ELF_FILES=()

# Follow a symlink chain the way the loader would inside the extracted tree: an
# absolute target names a path in the tree, not on the host running the test.
resolve_in_tree() {
    local path="$1" target hop
    for ((hop = 0; hop < MAX_SYMLINK_HOPS; hop++)); do
        if [[ ! -L "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
        target="$(readlink "$path")"
        if [[ "$target" == /* ]]; then
            path="$TREE$target"
        else
            path="$(dirname "$path")/$target"
        fi
    done
    return 1
}

# The loader finds a soname by looking the name itself up in the library
# directories, so a soname resolves only through a tree entry of that name —
# either the file or the link staged for it.
resolve_soname() {
    local name="$1" candidate resolved
    candidate="${TREE_PATH_BY_BASENAME[$name]:-}"
    [[ -n "$candidate" ]] || return 1
    resolved="$(resolve_in_tree "$candidate")" || return 1
    [[ -f "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
}

# Index every file/symlink reachable through the committed loader search path:
# each directory named in etc/ld.so.conf.d/*.conf, plus the loader's own
# directory. This is exactly the set the dynamic loader consults inside the
# sandbox, so a DT_NEEDED that resolves here resolves at runtime too.
index_tree() {
    local path dynamic needed soname conf dir line real
    local -a lib_dirs=()
    local -A seen_dirs=()

    while IFS= read -r conf; do
        while IFS= read -r line; do
            dir="${line%%#*}"
            dir="${dir//[[:space:]]/}"
            [[ -n "$dir" ]] && lib_dirs+=("$TREE$dir")
        done <"$conf"
    done < <(find "$TREE/etc/ld.so.conf.d" -maxdepth 1 -name '*.conf' 2>/dev/null)
    lib_dirs+=("$(dirname "$TREE$LOADER_PATH")")

    for dir in "${lib_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        real="$(cd "$dir" && pwd -P)"
        [[ -n "${seen_dirs[$real]:-}" ]] && continue
        seen_dirs["$real"]=1
        while IFS= read -r path; do
            # First wins: the same soname may legitimately be staged under both a
            # bare and a multiarch dir; either resolves the name for the loader.
            [[ -n "${TREE_PATH_BY_BASENAME["${path##*/}"]:-}" ]] && continue
            TREE_PATH_BY_BASENAME["${path##*/}"]="$path"
        done < <(find "$dir/" -mindepth 1 -maxdepth 1 \( -type f -o -type l \))
    done

    while IFS= read -r path; do
        dynamic="$(readelf -d "$path" 2>/dev/null)"
        [[ "$dynamic" == *"(NEEDED)"* || "$dynamic" == *"(SONAME)"* ]] || continue
        needed="$(printf '%s\n' "$dynamic" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
        soname="$(printf '%s\n' "$dynamic" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
        STAGED_ELF_FILES+=("$path")
        NEEDED_OF_FILE["$path"]="$needed"
        [[ -n "$soname" ]] && SONAME_OF_FILE["$path"]="$soname"
    done < <(find "$TREE" -type f)
}

# --- assertions --------------------------------------------------------------

slc_tarball_contains_executable_client() {
    local client="$TREE/$CLIENT_REL"
    if [[ ! -f "$client" ]]; then
        fail "slc_tarball_contains_executable_client: $CLIENT_REL is not a regular file in the tarball"; return
    fi
    if [[ ! -x "$client" ]]; then
        fail "slc_tarball_contains_executable_client: $CLIENT_REL is not executable"; return
    fi
    if [[ ! -s "$client" ]]; then
        fail "slc_tarball_contains_executable_client: $CLIENT_REL is empty"; return
    fi
    pass "slc_tarball_contains_executable_client"
}

slc_client_matches_host_arch_and_loader_resolves() {
    local host_machine client_machine loader
    host_machine="$(readelf -h /proc/self/exe 2>/dev/null | sed -n 's/^ *Machine: *//p')"
    if [[ -z "$host_machine" ]]; then
        fail "slc_client_matches_host_arch_and_loader_resolves: cannot read the host ELF machine from /proc/self/exe"; return
    fi
    client_machine="$(readelf -h "$TREE/$CLIENT_REL" 2>/dev/null | sed -n 's/^ *Machine: *//p')"
    if [[ "$client_machine" != "$host_machine" ]]; then
        fail "slc_client_matches_host_arch_and_loader_resolves: $CLIENT_REL is built for '$client_machine', runner is '$host_machine'"; return
    fi
    loader="$(resolve_in_tree "$TREE$LOADER_PATH")" || {
        fail "slc_client_matches_host_arch_and_loader_resolves: PT_INTERP '$LOADER_PATH' is a symlink loop inside the tree"; return
    }
    if [[ ! -f "$loader" ]]; then
        fail "slc_client_matches_host_arch_and_loader_resolves: PT_INTERP '$LOADER_PATH' does not resolve to a file inside the tree"; return
    fi
    if [[ ! -x "$loader" ]]; then
        fail "slc_client_matches_host_arch_and_loader_resolves: staged loader '$LOADER_PATH' is not executable"; return
    fi
    pass "slc_client_matches_host_arch_and_loader_resolves"
}

slc_tarball_dt_needed_closure_is_complete() {
    local path entry soname
    if [[ "${#STAGED_ELF_FILES[@]}" -eq 0 ]]; then
        fail "slc_tarball_dt_needed_closure_is_complete: the tarball holds no dynamic ELF at all"; return
    fi
    for path in "${STAGED_ELF_FILES[@]}"; do
        for entry in ${NEEDED_OF_FILE["$path"]}; do
            if ! resolve_soname "$entry" >/dev/null; then
                fail "slc_tarball_dt_needed_closure_is_complete: '${path#"$TREE/"}' needs '$entry', which does not resolve through the committed loader search path (etc/ld.so.conf.d)"; return
            fi
        done
        soname="${SONAME_OF_FILE["$path"]:-}"
        if [[ -n "$soname" ]] && ! resolve_soname "$soname" >/dev/null; then
            fail "slc_tarball_dt_needed_closure_is_complete: '${path#"$TREE/"}' declares soname '$soname', which does not resolve through etc/ld.so.conf.d — did the Dockerfile's ldconfig/mojo.conf step run?"; return
        fi
    done
    pass "slc_tarball_dt_needed_closure_is_complete"
}

slc_tarball_ld_so_conf_dirs_exist() {
    local conf="$TREE/etc/ld.so.conf.d/mojo.conf" dir count=0
    if [[ ! -s "$conf" ]]; then
        fail "slc_tarball_ld_so_conf_dirs_exist: etc/ld.so.conf.d/mojo.conf is missing or empty — the loader cache would not find the staged libraries"; return
    fi
    while IFS= read -r dir; do
        dir="${dir%%#*}"; dir="${dir//[[:space:]]/}"
        [[ -n "$dir" ]] || continue
        count=$((count + 1))
        if [[ ! -d "$TREE$dir" ]]; then
            fail "slc_tarball_ld_so_conf_dirs_exist: mojo.conf lists '$dir', which is not a directory in the tree"; return
        fi
    done <"$conf"
    if [[ "$count" -eq 0 ]]; then
        fail "slc_tarball_ld_so_conf_dirs_exist: mojo.conf names no directory"; return
    fi
    pass "slc_tarball_ld_so_conf_dirs_exist"
}

slc_tarball_has_no_shell_or_package_manager() {
    local path
    for path in "${FORBIDDEN_PAYLOAD_PATHS[@]}"; do
        if [[ -e "$TREE/$path" || -L "$TREE/$path" ]]; then
            fail "slc_tarball_has_no_shell_or_package_manager: tarball ships '$path'"; return
        fi
    done
    pass "slc_tarball_has_no_shell_or_package_manager"
}

slc_tarball_ships_sandbox_skeleton() {
    local name entries
    for name in "${SKELETON_DIRS[@]}"; do
        if [[ ! -d "$TREE/$name" ]]; then
            fail "slc_tarball_ships_sandbox_skeleton: $name is not a directory in the tarball"; return
        fi
        entries="$(find "$TREE/$name" \( -type f -o -type l -o -type b -o -type c -o -type p -o -type s \) 2>/dev/null)"
        if [[ -n "$entries" ]]; then
            fail "slc_tarball_ships_sandbox_skeleton: $name holds non-directory entries:
$entries"; return
        fi
    done
    pass "slc_tarball_ships_sandbox_skeleton"
}

slc_tarball_tmp_is_empty_and_world_writable() {
    local entries mode
    if [[ ! -d "$TREE/tmp" ]]; then
        fail "slc_tarball_tmp_is_empty_and_world_writable: tmp/ is missing — the sandbox needs a writable scratch dir"; return
    fi
    entries="$(find "$TREE/tmp" -mindepth 1)"
    if [[ -n "$entries" ]]; then
        fail "slc_tarball_tmp_is_empty_and_world_writable: tmp/ ships build-time content:
$entries"; return
    fi
    mode="$(stat -c '%a' "$TREE/tmp")"
    if [[ "$mode" != "1777" ]]; then
        fail "slc_tarball_tmp_is_empty_and_world_writable: tmp/ mode is '$mode', expected 1777"; return
    fi
    pass "slc_tarball_tmp_is_empty_and_world_writable"
}

slc_tarball_python_runtime_staged() {
    local libpython="$TREE/exaudf/libpython.so" soname stdlib
    if [[ ! -s "$libpython" ]]; then
        fail "slc_tarball_python_runtime_staged: exaudf/libpython.so is missing or empty — MOJO_PYTHON_LIBRARY would not resolve"; return
    fi
    # src/main.mojo bundles a fixed soname link next to the real file; the loader
    # resolves libpython by soname, so that name must resolve in the tree.
    soname="$(readelf -d "$libpython" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
    if [[ -n "$soname" ]] && ! resolve_soname "$soname" >/dev/null; then
        # libpython lives under exaudf/, which is not on the ld.so.conf path; the
        # sibling soname link is what makes it loadable, so check it directly.
        if [[ ! -e "$TREE/exaudf/$soname" ]]; then
            fail "slc_tarball_python_runtime_staged: libpython soname '$soname' has no sibling in exaudf/"; return
        fi
    fi
    stdlib="$(find "$TREE/usr/lib" -maxdepth 1 -type d -name 'python3.*' 2>/dev/null | head -1)"
    if [[ -z "$stdlib" ]]; then
        fail "slc_tarball_python_runtime_staged: no usr/lib/python3.* stdlib directory is staged"; return
    fi
    if [[ ! -f "$stdlib/os.py" ]]; then
        fail "slc_tarball_python_runtime_staged: ${stdlib#"$TREE/"}/os.py is missing — the stdlib was not staged"; return
    fi
    if [[ ! -d "$TREE/opt/pypkgs/pyudf" ]]; then
        fail "slc_tarball_python_runtime_staged: opt/pypkgs/pyudf (the bundled, extensible package) is missing"; return
    fi
    pass "slc_tarball_python_runtime_staged"
}

slc_tarball_language_definitions_well_formed() {
    local defs="$TREE/build_info/language_definitions.json"
    local source="$ROOT/build_info/language_definitions.json"
    local shape_output declared
    if [[ ! -s "$defs" ]]; then
        fail "slc_tarball_language_definitions_well_formed: build_info/language_definitions.json is missing or empty"; return
    fi
    if ! shape_output="$(bash "$HERE/language_definitions_test.sh" "$defs" 2>&1)"; then
        fail "slc_tarball_language_definitions_well_formed: shape check on $defs failed:
$shape_output"; return
    fi
    if [[ -f "$source" ]] && ! cmp -s "$defs" "$source"; then
        fail "slc_tarball_language_definitions_well_formed: shipped build_info/language_definitions.json is not byte-identical to committed $source"; return
    fi
    declared="$(jq -r '.language_definitions[0].udf_client_path.executable' "$defs")"
    if [[ ! -x "$TREE$declared" ]]; then
        fail "slc_tarball_language_definitions_well_formed: declared executable '$declared' is not an executable file in the tree"; return
    fi
    pass "slc_tarball_language_definitions_well_formed"
}

slc_tarball_tree_within_ceiling() {
    local total
    total="$(du -sb "$TREE" 2>/dev/null | cut -f1)"
    if [[ -z "$total" ]]; then
        fail "slc_tarball_tree_within_ceiling: cannot measure the extracted tree with 'du -sb'"; return
    fi
    echo "INFO: extracted tree is $total bytes (ceiling $STAGED_TREE_CEILING_BYTES)"
    if [[ "$total" -gt "$STAGED_TREE_CEILING_BYTES" ]]; then
        fail "slc_tarball_tree_within_ceiling: extracted tree $total bytes exceeds the committed ceiling $STAGED_TREE_CEILING_BYTES"; return
    fi
    pass "slc_tarball_tree_within_ceiling"
}

# --- runner ------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
    echo "usage: bash test/slc_tarball_test.sh <tarball>" >&2
    exit 2
fi
TARBALL="$1"
[[ -f "$TARBALL" ]] || die "no such tarball: $TARBALL"
command -v readelf >/dev/null 2>&1 || die "readelf not found — install binutils"
command -v jq >/dev/null 2>&1 || die "jq not found — install jq"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT
# -p keeps the archived modes verbatim; without it an ordinary user's umask
# rewrites them and every mode assertion here would test the runner's umask
# instead of the artifact BucketFS extracts as root.
tar -xzpf "$TARBALL" -C "$TREE" || die "cannot extract $TARBALL"

slc_tarball_contains_executable_client

# Every remaining ELF assertion reads the client or the index built from the
# tree, so a client that cannot be read at all stops the run instead of
# producing derived failures.
LOADER_PATH="$(readelf -l "$TREE/$CLIENT_REL" 2>/dev/null \
    | sed -n 's/.*interpreter: \(.*\)]/\1/p' | tr -d ' ')"
[[ -n "$LOADER_PATH" ]] || die "no PT_INTERP in $CLIENT_REL — cannot derive the loader path"

index_tree

slc_client_matches_host_arch_and_loader_resolves
slc_tarball_dt_needed_closure_is_complete
slc_tarball_ld_so_conf_dirs_exist
slc_tarball_has_no_shell_or_package_manager
slc_tarball_ships_sandbox_skeleton
slc_tarball_tmp_is_empty_and_world_writable
slc_tarball_python_runtime_staged
slc_tarball_language_definitions_well_formed
slc_tarball_tree_within_ceiling

if [[ "$failures" -gt 0 ]]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All tests passed"
