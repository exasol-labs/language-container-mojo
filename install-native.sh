#!/usr/bin/env bash
# install-native.sh — build, upload, and register the NATIVE Mojo language
# container (mojoudfclient) in one command.
#
# Trimmed sibling of the Rust project's scripts/install.sh: only the normal
# BucketFS-HTTP transport (cluster / docker-db / SaaS). It
#   1. builds out/mojo-slc.tar.gz via ./Dockerfile   (skip with MOJO_SLC_TARBALL)
#   2. uploads it to BucketFS
#   3. registers a MOJO alias -> .../exaudf/mojoudfclient, preserving every other
#      language already in SCRIPT_LANGUAGES (a stale MOJO entry is replaced).
#
# Requires: exapump; and docker (unless MOJO_SLC_TARBALL points at a prebuilt
# tarball). Run from the repo root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── defaults ──────────────────────────────────────────────────────────────────
HOST=""
PORT=8563
USER=sys
PASSWORD=""
BFS_PORT=2581
BFS_PASSWORD=""
BUCKET=default
BFS_SERVICE=bfsdefault
SLC_NAME=mojoslc
SCOPE=SESSION
ALIAS=MOJO

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build, upload, and register the native Mojo language container in Exasol.

Required:
  -H, --host HOST            Exasol host
  -p, --password PASS        Exasol DB password
  -w, --bfs-password PASS    BucketFS write password

Options:
  -P, --port PORT            Exasol DB port        (default: 8563)
  -u, --user USER            Exasol user           (default: sys)
      --bfs-port PORT        BucketFS HTTPS port   (default: 2581)
      --bucket NAME          BucketFS bucket       (default: default)
      --bfs-service NAME     BucketFS service      (default: bfsdefault)
      --slc-name NAME        SLC name in BucketFS  (default: mojoslc)
      --scope SESSION|SYSTEM ALTER scope           (default: SESSION)
  -h, --help                 Show this help

Environment:
  MOJO_SLC_TARBALL           Use this prebuilt tarball instead of docker build.
  MOJO_VERSION               Passed to the Docker build (--build-arg).

Example:
  $(basename "$0") --host localhost --password exasol --bfs-password secret
EOF
}

die() { echo "error: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not on PATH"; }

# ── args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host)         HOST="$2";        shift 2 ;;
    -P|--port)         PORT="$2";        shift 2 ;;
    -u|--user)         USER="$2";        shift 2 ;;
    -p|--password)     PASSWORD="$2";    shift 2 ;;
       --bfs-port)     BFS_PORT="$2";    shift 2 ;;
    -w|--bfs-password) BFS_PASSWORD="$2"; shift 2 ;;
       --bucket)       BUCKET="$2";      shift 2 ;;
       --bfs-service)  BFS_SERVICE="$2"; shift 2 ;;
       --slc-name)     SLC_NAME="$2";    shift 2 ;;
       --scope)        SCOPE="$2";       shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

require exapump
[[ -z "$HOST" ]]         && die "--host is required"
[[ -z "$PASSWORD" ]]     && die "--password is required"
[[ -z "$BFS_PASSWORD" ]] && die "--bfs-password is required"
[[ -z "$BFS_SERVICE" ]]  && die "--bfs-service must not be empty"
[[ -z "$BUCKET" ]]       && die "--bucket must not be empty"
[[ -z "$SLC_NAME" ]]     && die "--slc-name must not be empty"

SCOPE_UPPER="$(printf '%s' "$SCOPE" | tr '[:lower:]' '[:upper:]')"
[[ "$SCOPE_UPPER" == "SESSION" || "$SCOPE_UPPER" == "SYSTEM" ]] \
  || die "--scope must be SESSION or SYSTEM"

# ── step 1: build (or reuse) the tarball ──────────────────────────────────────
if [[ -n "${MOJO_SLC_TARBALL:-}" ]]; then
  echo "==> Using prebuilt tarball: ${MOJO_SLC_TARBALL}"
  TARBALL="$MOJO_SLC_TARBALL"
else
  require docker
  OUT_DIR="$(mktemp -d /tmp/mojo-slc-XXXXXX)"
  trap 'rm -rf "$OUT_DIR"' EXIT
  echo "==> Building native Mojo SLC via Dockerfile …"
  docker build \
    -f "$SCRIPT_DIR/Dockerfile" \
    --target artifact \
    ${MOJO_VERSION:+--build-arg "MOJO_VERSION=${MOJO_VERSION}"} \
    --output "type=local,dest=$OUT_DIR" \
    "$SCRIPT_DIR"
  TARBALL="$OUT_DIR/mojo-slc.tar.gz"
fi
[[ -f "$TARBALL" ]] || die "SLC tarball not found: $TARBALL"
echo "==> Tarball ready: $TARBALL ($(du -sh "$TARBALL" | cut -f1))."

# ── step 2: upload to BucketFS ────────────────────────────────────────────────
BFS_PATH="slc/${SLC_NAME}.tar.gz"
SLC_PATH="slc/${SLC_NAME}"
echo "==> Uploading to BucketFS: ${BFS_SERVICE}/${BUCKET}/${BFS_PATH} …"
exapump bucketfs cp "$TARBALL" "$BFS_PATH" \
  --bfs-host "$HOST" \
  --bfs-port "$BFS_PORT" \
  --bfs-bucket "$BUCKET" \
  --bfs-write-password "$BFS_PASSWORD" \
  --bfs-tls true \
  --bfs-validate-certificate false
echo "==> Upload complete."

# ── step 3: register, preserving existing languages ───────────────────────────
DSN="exasol://${USER}:${PASSWORD}@${HOST}:${PORT}?validateservercertificate=0"
ENTRY="${ALIAS}=localzmq+protobuf:///${BFS_SERVICE}/${BUCKET}/${SLC_PATH}?lang=mojo#buckets/${BFS_SERVICE}/${BUCKET}/${SLC_PATH}/exaudf/mojoudfclient"

# Current SCRIPT_LANGUAGES value (may be empty). Strip header + surrounding quotes.
CURRENT="$(exapump sql -f csv \
  "SELECT SYSTEM_VALUE FROM EXA_PARAMETERS WHERE PARAMETER_NAME = 'SCRIPT_LANGUAGES'" \
  -d "$DSN" 2>/dev/null | tail -n1 || true)"
CURRENT="${CURRENT%\"}"; CURRENT="${CURRENT#\"}"
case "$CURRENT" in SYSTEM_VALUE|CURRENT_SCRIPT_LANGUAGES) CURRENT="" ;; esac

# Keep every entry except a stale MOJO=, then append the fresh one.
KEPT=()
read -ra WORDS <<<"$CURRENT"
for w in ${WORDS[@]+"${WORDS[@]}"}; do
  case "$w" in "${ALIAS}="*) continue ;; esac
  KEPT+=("$w")
done
KEPT+=("$ENTRY")
SCRIPT_LANGUAGES="${KEPT[*]}"

echo "==> Registering ${ALIAS} at ${HOST}:${PORT} (ALTER ${SCOPE_UPPER} SET SCRIPT_LANGUAGES) …"
exapump sql "ALTER ${SCOPE_UPPER} SET SCRIPT_LANGUAGES='${SCRIPT_LANGUAGES}'" -d "$DSN"
echo "==> Done. The ${ALIAS} script language is now available."
echo
echo "    SCRIPT_LANGUAGES entry:"
echo "    ${ENTRY}"
