#!/bin/bash
# Build one (config, arch) pair out-of-tree using ccache.
# Usage: build.sh <config> <arch>
# Writes build/<config>-<arch>/build.status: PASS | FAIL
set -euo pipefail
. "$(dirname "$0")/common.sh"

CONFIG=${1:?usage: build.sh <config> <arch>}
ARCH=${2:?usage: build.sh <config> <arch>}

require_env KERNEL_TREE BUILD_DIR CACHE_DIR RUN_STAMP

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

# Kernel make wrapper — respects V for verbosity
kmake() {
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
        make "${make_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    else
        make "${make_args[@]}" >> "$LOG_FILE" 2>&1
    fi
}

BUILD_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD_START_EPOCH=$(date -u +%s)

# Step 1: generate .config
info "Configuring $CONFIG / $ARCH"
if ! kmake "$CONFIG"; then
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

# Step 2: build bzImage
# For allmodconfig the goal is catching compilation errors; bzImage covers the
# core kernel. Module compilation is a future improvement (takes much longer).
info "Building bzImage ($NPROC jobs) — $CONFIG / $ARCH"
if ! kmake -j"$NPROC" bzImage; then
    printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\n' \
        "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" > "$STATUS_FILE"
    die "Build failed: $CONFIG / $ARCH — see $LOG_FILE"
fi

printf 'STATUS=PASS\nSTART_TIME=%s\nDURATION=%d\n' \
    "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" > "$STATUS_FILE"
info "Build OK: $CONFIG / $ARCH"
