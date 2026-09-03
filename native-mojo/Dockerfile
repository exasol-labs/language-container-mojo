# Dockerfile — build + package the NATIVE Mojo language container (mojoudfclient).
#
# Produces an SLC tarball whose rootfs is a hermetic tree containing only the
# Mojo binary, its dynamic loader, and its full shared-object closure (libzmq +
# the Mojo runtime libs). No Rust anywhere.
#
#   docker build -f Dockerfile --target artifact --output type=local,dest=./out .
#   # (build context = this native-mojo/ directory)
#
# The closure is resolved in the BUILDER stage, where the Mojo runtime and libzmq
# are installed and every NEEDED/RPATH lib resolves; the staging stage only
# packages that finished /slc tree (running the closure walk in a stage without
# the Mojo runtime would silently skip libKGENCompilerRTShared.so & friends).
#
# VERIFY: the Mojo install channel/version below against your release.

# ── Stage 1: builder — compile AND assemble the /slc rootfs ───────────────────
# Debian trixie so the bundled glibc matches Exasol's container base.
FROM debian:trixie AS builder

# libzmq5: src/zmq.mojo dlopens libzmq.so.5 at runtime; it (and its own closure)
# must be present here so the ldd walk can resolve and stage it. clang/lld cover
# the linker mojo shells out to.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates python3 python3-pip clang lld libzmq5 \
    && rm -rf /var/lib/apt/lists/*

# VERIFY: install channel + version for your Mojo release. Modular ships Mojo via
# the `modular` pip package on the 1.0 line; pin the version you build UDFs with.
ARG MOJO_VERSION=25.6
RUN pip install --break-system-packages "modular==${MOJO_VERSION}"
# VERIFY: put the `mojo` binary on PATH (pip installs a console script).
ENV PATH="/usr/local/bin:${PATH}"

WORKDIR /build
COPY src/ ./src/

# No link flags: libzmq is dlopen'd at runtime (src/zmq.mojo).
RUN mojo build src/main.mojo -o /build/mojoudfclient \
    && test -x /build/mojoudfclient

# Fail early if any NEEDED lib is unresolved *here* (where the Mojo runtime lives).
RUN if ldd /build/mojoudfclient | grep -q "not found"; then \
        echo "error: mojoudfclient has unresolved shared libraries:" >&2; \
        ldd /build/mojoudfclient >&2; exit 1; \
    fi

# Assemble the hermetic rootfs /slc: the binary, the full transitive shared-object
# closure of BOTH the binary and libzmq.so.5 (dlopen'd → absent from the binary's
# ldd), libzmq itself, and the dynamic loader — all at their real absolute paths
# so RPATH/absolute NEEDED entries resolve unchanged after BucketFS extraction.
RUN set -eu; \
    mkdir -p /slc/exaudf; \
    cp /build/mojoudfclient /slc/exaudf/mojoudfclient; \
    chmod +x /slc/exaudf/mojoudfclient; \
    # Walk ldd on the ORIGINAL binary path (where the builder sanity check
    # resolved it) so an $ORIGIN-relative RPATH still finds the Mojo runtime libs.
    SRC=/build/mojoudfclient; \
    LIBZMQ="$(ldconfig -p | sed -nE 's/.*libzmq\.so\.5 .*=> (\/.*)/\1/p' | head -n1)"; \
    [ -n "$LIBZMQ" ] || { echo "error: libzmq.so.5 not found by ldconfig" >&2; exit 1; }; \
    for T in "$SRC" "$LIBZMQ"; do \
        ldd "$T" | while IFS= read -r line; do \
            case "$line" in \
                *"=> /"*) p=$(printf '%s' "$line" | sed -nE 's/.*=> (\/[^ ]+).*/\1/p') ;; \
                /*)       p=$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*(\/[^ ]+).*/\1/p') ;; \
                *)        p="" ;; \
            esac; \
            if [ -n "$p" ] && [ -e "$p" ]; then \
                mkdir -p "/slc$(dirname "$p")"; cp -Lu "$p" "/slc$p"; \
            fi; \
        done; \
    done; \
    mkdir -p "/slc$(dirname "$LIBZMQ")"; cp -Lu "$LIBZMQ" "/slc$LIBZMQ"; \
    LOADER="$(ldd "$SRC" | sed -nE 's|^[[:space:]]*(/lib[^ ]*ld-[^ ]+).*|\1|p' | head -n1)"; \
    if [ -n "$LOADER" ] && [ ! -e "/slc$LOADER" ]; then \
        mkdir -p "/slc$(dirname "$LOADER")"; cp -L "$LOADER" "/slc$LOADER"; \
    fi; \
    mkdir -p /slc/tmp /slc/etc/ld.so.conf.d; chmod 1777 /slc/tmp; \
    printf 'passwd: files\ngroup: files\nhosts: files dns\n' > /slc/etc/nsswitch.conf; \
    printf 'include /etc/ld.so.conf.d/*.conf\n' > /slc/etc/ld.so.conf; \
    # Register EVERY staged lib directory in the loader cache, so libs resolve via
    # ld.so.cache even when the binary's RPATH is $ORIGIN-relative and misses.
    find /slc -type f -name '*.so*' | sed 's#^/slc##; s#/[^/]*$##' | sort -u \
        > /slc/etc/ld.so.conf.d/mojo.conf; \
    ldconfig -r /slc || true

COPY build_info/ /slc/build_info/

# ── Stage 2: packager ─────────────────────────────────────────────────────────
# A clean slim base: only packages the pre-assembled rootfs, proves it loads, tars.
FROM debian:trixie-slim AS staging

COPY --from=builder /slc /slc

# Prove the binary loads inside the rootfs before shipping: a no-argument run
# returns non-zero with the wrong-argument-count message (an endpoint arg would
# block on connect instead).
RUN set +e; \
    OUTPUT="$(chroot /slc /exaudf/mojoudfclient 2>&1)"; \
    STATUS=$?; \
    set -e; \
    if [ "$STATUS" -eq 0 ]; then \
        echo "error: chroot self-test exited 0, expected non-zero" >&2; exit 1; \
    fi; \
    case "$OUTPUT" in \
        *"wrong argument count"*) ;; \
        *) echo "error: chroot self-test missing wrong-argument-count message:" >&2; \
           echo "$OUTPUT" >&2; exit 1 ;; \
    esac

RUN find /slc/tmp -mindepth 1 -delete 2>/dev/null || true
RUN tar --hard-dereference -C /slc -czf /mojo-slc.tar.gz .

# ── Stage: selftest — run the real protocol against a fake Exasol (Linux) ─────
# Runs on macOS too (Docker is Linux). Drives mojoudfclient through the full
# MT_* exchange with test/fake_exasol.py and prints a per-message trace, so an
# empty/None result becomes a precise "container sent X, expected Y".
#   docker build -f Dockerfile --target selftest .
FROM debian:trixie-slim AS selftest
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-zmq coreutils \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /slc /slc
COPY test/fake_exasol.py /fake_exasol.py
RUN set -u; \
    echo "=== starting fake Exasol ==="; \
    python3 /fake_exasol.py --bind tcp://127.0.0.1:6583 > /fake.out 2>&1 & \
    FAKE=$!; \
    sleep 1; \
    echo "=== launching mojoudfclient (chroot) ==="; \
    timeout 20 chroot /slc /exaudf/mojoudfclient tcp://127.0.0.1:6583 lang=mojo; \
    echo "=== container exit code: $? ==="; \
    wait "$FAKE" 2>/dev/null || true; \
    echo "=== fake Exasol trace ==="; \
    cat /fake.out; \
    echo "==="; \
    grep -q "OK: doubling verified" /fake.out

# ── Stage 3: artifact ─────────────────────────────────────────────────────────
FROM scratch AS artifact
COPY --from=staging /mojo-slc.tar.gz /
