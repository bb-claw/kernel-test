#!/bin/bash
# Build one (config, arch) pair out-of-tree using ccache.
# Usage: build.sh <config> <arch>
# Writes build/<config>-<arch>/build.status: PASS | FAIL
set -euo pipefail
. "$(dirname "$0")/common.sh"

CONFIG=${1:?usage: build.sh <config> <arch>}
ARCH=${2:?usage: build.sh <config> <arch>}

require_env KERNEL_TREE BUILD_DIR CACHE_DIR RUN_STAMP
BUILD_TIMEOUT=${BUILD_TIMEOUT:-600}

# Catch an empty/missing working tree early with a clear message
[[ -f "$KERNEL_TREE/Makefile" ]] || \
    die "Kernel Makefile not found in '$KERNEL_TREE' — run 'make fetch' first, " \
        "or restore the tree with: git -C $KERNEL_TREE checkout HEAD -- ."

OUT_DIR="$BUILD_DIR/$CONFIG-$ARCH"
LOG_FILE="$OUT_DIR/build.log"
STATUS_FILE="$OUT_DIR/build.status"
NPROC=$(nproc 2>/dev/null || echo 1)

mkdir -p "$OUT_DIR"
: > "$LOG_FILE"

# ccache: point at our local cache dir and expose via CC/HOSTCC
export CCACHE_DIR="$PWD/$CACHE_DIR"
mkdir -p "$CCACHE_DIR"

# Validate ccache is available
command -v ccache &>/dev/null || die "ccache not found in PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FRAGMENT="$SCRIPT_DIR/configs/${CONFIG}.config"

# Kernel make wrapper — respects V for verbosity.
# Pass --timed as the first argument to enforce BUILD_TIMEOUT on the make call.
kmake() {
    local pfx=()
    if [[ ${1:-} == --timed ]]; then
        shift
        [[ $BUILD_TIMEOUT -gt 0 ]] && pfx=( timeout "$BUILD_TIMEOUT" )
    fi
    local make_args=(
        -C "$KERNEL_TREE"
        O="$PWD/$OUT_DIR"
        ARCH="$ARCH"
        CC="ccache gcc"
        HOSTCC="ccache gcc"
        KBUILD_BUILD_TIMESTAMP="$RUN_STAMP"
        "$@"
    )
    if [[ ${V:-0} == 1 ]]; then
        "${pfx[@]}" make "${make_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    else
        "${pfx[@]}" make "${make_args[@]}" >> "$LOG_FILE" 2>&1
    fi
}

BUILD_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD_START_EPOCH=$(date -u +%s)

# Step 1: generate .config
info "Configuring $CONFIG / $ARCH"
if [[ $CONFIG == rand500config ]]; then
    # Base: tinyconfig (tiny, known-bootable kernel)
    if ! kmake tinyconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    fi
    # Generate a fresh randconfig in a temp dir, constrain it to exclude heavy
    # subsystems (same set as configs/randconfig.config), then sample 500 =y lines.
    # Constraining before sampling prevents accidentally pulling in DRM/SOUND/etc.
    # 500 lines compensates for dependency attrition: many options get discarded by
    # olddefconfig when their prerequisites are absent in the tinyconfig base.
    RAND_TMP=$(mktemp -d)
    trap 'rm -rf "$RAND_TMP"' EXIT
    make -C "$KERNEL_TREE" O="$RAND_TMP" ARCH="$ARCH" \
        KBUILD_BUILD_TIMESTAMP="$RUN_STAMP" randconfig >> "$LOG_FILE" 2>&1
    cat "$SCRIPT_DIR/configs/randconfig.config" >> "$RAND_TMP/.config"
    make -C "$KERNEL_TREE" O="$RAND_TMP" ARCH="$ARCH" \
        KBUILD_BUILD_TIMESTAMP="$RUN_STAMP" olddefconfig >> "$LOG_FILE" 2>&1
    cp "$RAND_TMP/.config" "$OUT_DIR/rand-source.config"
    grep '^CONFIG_[A-Z0-9_]*=y$' "$RAND_TMP/.config" | shuf -n 500 \
        | tee "$OUT_DIR/rand-sampled.config" >> "$PWD/$OUT_DIR/.config"
    rm -rf "$RAND_TMP"
    trap - EXIT
elif [[ $CONFIG == randdefconfig ]]; then
    # Base: defconfig (broad, coherent, realistic baseline)
    if ! kmake defconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    fi
    # Randomly disable ~300 options to reduce build surface.
    # The fragment (step 1b) forces heavy subsystems off and re-pins bootability options,
    # so olddefconfig resolves any cascading conflicts safely.
    grep '^CONFIG_[A-Z0-9_]*=[ym]$' "$PWD/$OUT_DIR/.config" | shuf -n 300 \
        | sed 's/=[ym]$/=n/' \
        | tee "$OUT_DIR/randdef-disabled.config" >> "$PWD/$OUT_DIR/.config"
elif [[ $CONFIG == localconfig ]]; then
    # localconfig: running kernel's config as base — for daily-driver builds.
    # Requires CONFIG_IKCONFIG_PROC=y (provides /proc/config.gz).
    [[ -r /proc/config.gz ]] || \
        die "localconfig requires /proc/config.gz — enable CONFIG_IKCONFIG_PROC in your running kernel"
    zcat /proc/config.gz > "$PWD/$OUT_DIR/.config"
    if ! kmake olddefconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    fi
elif ! kmake "$CONFIG"; then
    printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\n' \
        "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" > "$STATUS_FILE"
    die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
fi

# Step 1b: apply config fragment (post-config, works for all kernel targets)
# KCONFIG_ALLCONFIG is NOT used here because some targets (e.g. tinyconfig)
# explicitly override it internally, silently discarding our fragment.
# Appending to .config + olddefconfig is reliable for every kernel target.
if [[ -f $FRAGMENT ]]; then
    info "Applying config fragment: $FRAGMENT"
    cat "$FRAGMENT" >> "$PWD/$OUT_DIR/.config"
    if ! kmake olddefconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" > "$STATUS_FILE"
        die "Config fragment failed: $FRAGMENT — see $LOG_FILE"
    fi
fi

# Fingerprint the final .config — config is now fully resolved
CONFIG_SHA256=$(sha256sum "$PWD/$OUT_DIR/.config" | awk '{print $1}')
info "Config SHA256: $CONFIG_SHA256 — $CONFIG / $ARCH"

# Step 2: build bzImage
# For build-only configs (allmodconfig, randconfig) the goal is catching
# compilation errors; bzImage covers the core kernel.
[[ $BUILD_TIMEOUT -gt 0 ]] \
    && info "Building bzImage ($NPROC jobs, timeout ${BUILD_TIMEOUT}s) — $CONFIG / $ARCH" \
    || info "Building bzImage ($NPROC jobs) — $CONFIG / $ARCH"
BUILD_EXIT=0
kmake --timed -j"$NPROC" bzImage || BUILD_EXIT=$?
if [[ $BUILD_EXIT -ne 0 ]]; then
    if [[ $BUILD_EXIT -eq 124 ]]; then
        printf 'STATUS=TIMEOUT\nSTART_TIME=%s\nDURATION=%d\nCONFIG_SHA256=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$CONFIG_SHA256" > "$STATUS_FILE"
        die "Build timed out after ${BUILD_TIMEOUT}s: $CONFIG / $ARCH — see $LOG_FILE"
    fi
    printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nCONFIG_SHA256=%s\n' \
        "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$CONFIG_SHA256" > "$STATUS_FILE"
    die "Build failed: $CONFIG / $ARCH — see $LOG_FILE"
fi

printf 'STATUS=PASS\nSTART_TIME=%s\nDURATION=%d\nCONFIG_SHA256=%s\n' \
    "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$CONFIG_SHA256" > "$STATUS_FILE"
info "Build OK: $CONFIG / $ARCH"
