# Dockerfile — build + package the NATIVE Mojo language container (mojoudfclient).
#
# Produces an SLC tarball whose rootfs is a hermetic tree containing only the
# Mojo binary, its dynamic loader, and its full shared-object closure (libzmq +
# the Mojo runtime libs). No Rust anywhere.
#
#   docker build -f Dockerfile --target artifact --output type=local,dest=./out .
#   # (build context = the repo root)
#
# The closure is resolved in the BUILDER stage, where the Mojo runtime and libzmq
# are installed and every NEEDED/RPATH lib resolves; the staging stage only
# packages that finished /slc tree (running the closure walk in a stage without
# the Mojo runtime would silently skip libKGENCompilerRTShared.so & friends).
#
# VERIFY: the Mojo install channel/version below against your release.

# ── Stage 1: builder — compile AND assemble the /slc rootfs ───────────────────
# Debian trixie so the bundled glibc matches Exasol's container base. Pinned by
# digest for supply-chain reproducibility — bump deliberately to pick up updates
# (multi-arch manifest digests; verify with `docker manifest inspect`).
FROM debian:trixie@sha256:f324c7ff54321e8d9c588493a20244965938ce0aa50bbd1022d38010e9ffc4b1 AS builder

# libzmq5: src/zmq.mojo dlopens libzmq.so.5 at runtime; it (and its own closure)
# must be present here so the ldd walk can resolve and stage it. clang/lld cover
# the linker mojo shells out to.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates python3 python3-dev python3-pip clang lld libzmq5 \
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
# ENTRY selects the entry module: main.mojo (default) or diag.mojo (a diagnostic
# build that reports Exasol's actual input encoding via the MT_CLOSE error).
ARG ENTRY=main.mojo
RUN mojo build "src/${ENTRY}" -o /build/mojoudfclient \
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
    # nschroot bind-mounts the rootfs read-only before it prepares these mount
    # points. They must therefore already exist in the packaged SLC.
    mkdir -p /slc/tmp /slc/var/tmp /slc/buckets /slc/dev/pts /slc/dev/shm \
        /slc/proc /slc/sys /slc/run/secrets /slc/etc/ld.so.conf.d; \
    chmod 1777 /slc/tmp /slc/var/tmp; \
    printf 'passwd: files\ngroup: files\nhosts: files dns\n' > /slc/etc/nsswitch.conf; \
    printf 'include /etc/ld.so.conf.d/*.conf\n' > /slc/etc/ld.so.conf; \
    # Register EVERY staged lib directory in the loader cache, so libs resolve via
    # ld.so.cache even when the binary's RPATH is $ORIGIN-relative and misses.
    find /slc -type f -name '*.so*' | sed 's#^/slc##; s#/[^/]*$##' | sort -u \
        > /slc/etc/ld.so.conf.d/mojo.conf; \
    ldconfig -r /slc || true

COPY build_info/ /slc/build_info/

# ── Bundle a minimal CPython so Mojo's Python interop works inside the SLC ─────
# The Mojo binary dlopens libpython at runtime (not in its ldd; guided by env set
# in src/main.mojo). Stage libpython + its closure, the stdlib (incl. lib-dynload
# and each C-extension's own shared-lib deps), any pip packages from
# requirements.txt, and the bundled pyudf/ package — the last two on PYTHONPATH
# at /opt/pypkgs so the Python side is extensible (add a line, rebuild).
COPY requirements.txt /build/requirements.txt
COPY python/ /build/python/
RUN set -eu; \
    PYVER="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')"; \
    LIBDIR="$(python3 -c 'import sysconfig;print(sysconfig.get_config_var("LIBDIR"))')"; \
    SONAME="$(python3 -c 'import sysconfig;print(sysconfig.get_config_var("INSTSONAME"))')"; \
    STD="/usr/lib/python$PYVER"; \
    stage_closure() { ldd "$1" 2>/dev/null | sed -nE 's/.*=> (\/[^ ]+).*/\1/p' | while read -r p; do [ -e "$p" ] && { mkdir -p "/slc$(dirname "$p")"; cp -Lu "$p" "/slc$p"; }; done; }; \
    # libpython + its shared-lib closure, plus a copy at a FIXED, arch-independent
    # path so src/main.mojo can point MOJO_PYTHON_LIBRARY at it (a bare soname
    # does not resolve for Mojo's Python loader inside the sandbox).
    mkdir -p "/slc$LIBDIR"; cp -Lu "$LIBDIR/$SONAME" "/slc$LIBDIR/$SONAME"; stage_closure "$LIBDIR/$SONAME"; \
    cp -Lu "$LIBDIR/$SONAME" /slc/exaudf/libpython.so; \
    # the stdlib (trim heavy, UDF-irrelevant parts), incl. lib-dynload
    mkdir -p "/slc$STD"; cp -a "$STD/." "/slc$STD/"; \
    rm -rf "/slc$STD/test" "/slc$STD/idlelib" "/slc$STD/tkinter" "/slc$STD/turtledemo" "/slc$STD/ensurepip"; \
    find "/slc$STD" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true; \
    # shared-lib deps of every C extension module
    for so in "/slc$STD"/lib-dynload/*.so; do [ -e "$so" ] && stage_closure "$so"; done; \
    # extra pip packages + the bundled pyudf package -> /opt/pypkgs (PYTHONPATH)
    mkdir -p /slc/opt/pypkgs; \
    pip install --break-system-packages --target=/slc/opt/pypkgs -r /build/requirements.txt; \
    cp -a /build/python/. /slc/opt/pypkgs/; \
    # refresh the loader cache to include libpython + extension deps
    find /slc -type f -name '*.so*' | sed 's#^/slc##; s#/[^/]*$##' | sort -u > /slc/etc/ld.so.conf.d/mojo.conf; \
    ldconfig -r /slc || true; \
    echo "bundled CPython $PYVER ($SONAME) + stdlib into the SLC"

# Build the example dynamic-UDF shared object (the extension path). It is built
# here (where the Mojo toolchain lives) but deliberately NOT staged into /slc —
# it must not ship in the artifact tarball, since `buckets/` is an empty sandbox
# mount point (asserted by the tarball contract test). The selftest stage copies
# it into its own throwaway chroot to exercise %udf_object loading.
COPY examples/udf_so/ /build/examples/udf_so/
RUN mojo build --emit shared-lib /build/examples/udf_so/double_ext.mojo \
        -o /build/double_ext.so \
    && test -s /build/double_ext.so

# ── Stage 2: packager ─────────────────────────────────────────────────────────
# A clean slim base: only packages the pre-assembled rootfs, proves it loads, tars.
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS staging

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
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS selftest
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-zmq coreutils \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /slc /slc
COPY test/fake_exasol.py /fake_exasol.py
# The example .so goes into THIS chroot only (not the shipped tarball) so the
# selftest can exercise the dynamic %udf_object load path.
COPY --from=builder /build/double_ext.so /slc/buckets/double_ext.so
# Exercise every UDF/wire combination the container supports: DOUBLE_MOJO
# (scalar) and SUM_POSITIVE (set) over the INT64 block, DOUBLE_MOJO over the
# NUMERIC/string block, and PY_SCALE (Python interop). Each case runs the real
# binary in the chroot against the fake Exasol; the build fails if any diverges.
# The Mojo runtime (LLVM host-CPU detection in libKGENCompilerRTShared.so) reads
# /proc/cpuinfo when it JITs the Python-interop bridge. The chroot has no mounted
# /proc, so on x86_64 that read hangs and the container never emits (arm64
# tolerates the absence — which is why this only failed on x86 CI). Exasol's real
# sandbox bind-mounts /proc; an unprivileged `docker build` RUN cannot `mount -t
# proc`, so drop a static copy of the builder's cpuinfo into the chroot. This is
# selftest-only: the shipped SLC tarball (staging stage) keeps /slc/proc an empty
# mount point, so production is unaffected.
RUN set -u; \
    # The Mojo runtime's LLVM host-CPU detection reads /proc/cpuinfo AND
    # /sys/devices/system/cpu/.../cache; the chroot mounts neither, so drop
    # static copies from the build container (real /proc, /sys) so x86_64 CPU
    # detection succeeds. Selftest-only; Exasol bind-mounts the real trees.
    cp /proc/cpuinfo /slc/proc/cpuinfo 2>/dev/null || true; \
    mkdir -p /slc/sys/devices/system/cpu; \
    cp -a /sys/devices/system/cpu/cpu0 /slc/sys/devices/system/cpu/ 2>/dev/null || true; \
    run_case() { \
        echo "=== case: fake_exasol $* ==="; \
        python3 /fake_exasol.py "$@" > /fake.out 2>&1 & FAKE=$!; \
        sleep 1; \
        timeout 40 chroot /slc /exaudf/mojoudfclient tcp://127.0.0.1:6583 lang=mojo > /c.out 2>&1 || true; \
        wait "$FAKE" 2>/dev/null || true; \
        cat /fake.out; \
        grep -qE "^OK:" /fake.out || { echo "SELFTEST FAILED for: fake_exasol $*"; \
            echo "----- container stderr (/c.out) -----"; cat /c.out; \
            echo "----- fake DB trace (/fake.out) -----"; cat /fake.out; \
            exit 1; }; \
        sleep 1; \
    }; \
    run_case; \
    run_case --sum; \
    run_case --numeric; \
    run_case --pyscale; \
    run_case --splits 3; \
    run_case --sum --splits 2; \
    run_case --emit; \
    echo "--- dynamic .so extension path (%udf_object) ---"; \
    run_case --udfobject /buckets/double_ext.so; \
    echo "--- SQL datatype compatibility matrix ---"; \
    run_case --coltype BIGINT; \
    run_case --coltype INTEGER; \
    run_case --coltype DECIMAL; \
    run_case --coltype DOUBLE; \
    run_case --coltype BOOLEAN; \
    run_case --coltype VARCHAR; \
    run_case --coltype DATE; \
    run_case --coltype TIMESTAMP; \
    echo "=== ALL SELFTEST CASES PASSED ==="

# ── Stage: unittest — pure codec unit tests (no ZMQ, no Exasol) ───────────────
# The Mojo analogue of the Rust SLC's per-module *_tests.rs. Compiled and run in
# the builder image (which has the Mojo toolchain + src/), so a codec regression
# fails the build before the protocol self-test would.
#   docker build -f Dockerfile --target unittest .
FROM builder AS unittest
COPY test/mojo/ /build/test/mojo/
RUN set -eu; \
    mojo build /build/test/mojo/test_codec.mojo -o /build/test_codec -I /build/src; \
    /build/test_codec

# ── Stage 3: artifact ─────────────────────────────────────────────────────────
FROM scratch AS artifact
COPY --from=staging /mojo-slc.tar.gz /
