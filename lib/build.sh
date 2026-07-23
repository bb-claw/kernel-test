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
GCC=${GCC:-gcc}         # override with e.g. GCC=gcc-15 for older stable kernels

# ── Architecture-specific settings ───────────────────────────────────────────

case "$ARCH" in
    x86_64)
        CROSS_COMPILE=''
        KERNEL_IMAGE_NAME=bzImage
        KERNEL_CC="$GCC"
        ;;
    i386)
        CROSS_COMPILE=''
        KERNEL_IMAGE_NAME=bzImage
        KERNEL_CC="$GCC"
        ;;
    arm64)
        CROSS_COMPILE='aarch64-linux-gnu-'
        KERNEL_IMAGE_NAME=Image
        KERNEL_CC="${CROSS_COMPILE}gcc"
        BUILD_TIMEOUT=$(( BUILD_TIMEOUT * 2 ))
        ;;
    *)
        die "Unsupported arch: $ARCH"
        ;;
esac

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
rm -f "$OUT_DIR/vm.status"   # clear stale test results so a failed build never shows old PASS data

# ── Kernel source identity ────────────────────────────────────────────────────

TREE_TAG=$(git -C "$KERNEL_TREE" describe --exact-match HEAD 2>/dev/null \
           || git -C "$KERNEL_TREE" describe --tags --abbrev=0 HEAD 2>/dev/null \
           || echo "(untagged)")
TREE_COMMIT=$(git -C "$KERNEL_TREE" rev-parse --short HEAD 2>/dev/null || echo "?")
TREE_URL=$(git -C "$KERNEL_TREE" remote get-url origin 2>/dev/null || echo "(no remote)")
info "Kernel: $TREE_TAG ($TREE_COMMIT) — $TREE_URL"
info "Tree:   $KERNEL_TREE"

# ccache: point at our local cache dir and expose via CC/HOSTCC
# shellcheck disable=SC2153  # CACHE_DIR is exported by the Makefile, not set here
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
        CC="ccache $KERNEL_CC"
        HOSTCC="ccache $GCC"
        KBUILD_BUILD_TIMESTAMP="$RUN_STAMP"
        "$@"
    )
    [[ -n $CROSS_COMPILE ]] && make_args+=( CROSS_COMPILE="$CROSS_COMPILE" )
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
if [[ -n "${SEED_CONFIG:-}" ]]; then
    info "Seeding .config from: $SEED_CONFIG"
    cp "$SEED_CONFIG" "$PWD/$OUT_DIR/.config"
    if ! kmake olddefconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config step failed (seed olddefconfig): $CONFIG / $ARCH — see $LOG_FILE"
    fi
elif [[ $CONFIG == rand500config ]]; then
    # Base: tinyconfig (tiny, known-bootable kernel)
    if ! kmake tinyconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
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
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    fi
    # Randomly disable ~300 options to reduce build surface.
    # The fragment (step 1b) forces heavy subsystems off and re-pins bootability options,
    # so olddefconfig resolves any cascading conflicts safely.
    grep '^CONFIG_[A-Z0-9_]*=[ym]$' "$PWD/$OUT_DIR/.config" | shuf -n 300 \
        | sed 's/=[ym]$/=n/' > "$OUT_DIR/randdef-disabled.config"
    cat "$OUT_DIR/randdef-disabled.config" >> "$PWD/$OUT_DIR/.config"
elif [[ $CONFIG == kunitconfig ]]; then
    # kunitconfig: defconfig base + KUnit test suites (applied in step 1b).
    # 'kunitconfig' is not a kernel make target — use defconfig as the base.
    if ! kmake defconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    fi
elif [[ $CONFIG == kunitrandconfig ]]; then
    # Enumerate every CONFIG_*KUNIT* from a fresh randconfig (full option set for
    # this arch), append to defconfig base.  olddefconfig (step 1b) drops any
    # module whose deps are unmet — only valid, buildable options survive.
    if ! kmake defconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    fi
    RAND_TMP=$(mktemp -d)
    trap 'rm -rf "$RAND_TMP"' EXIT
    make -C "$KERNEL_TREE" O="$RAND_TMP" ARCH="$ARCH" \
        KBUILD_BUILD_TIMESTAMP="$RUN_STAMP" randconfig >> "$LOG_FILE" 2>&1
    # Force =m → =y: initramfs cannot load modules, tests must be built-in.
    grep '^CONFIG_[A-Z0-9_]*KUNIT[A-Z0-9_]*=[ym]$' "$RAND_TMP/.config" \
        | sed 's/=[ym]$/=y/' \
        | tee "$OUT_DIR/kunitrand-sampled.config" >> "$PWD/$OUT_DIR/.config"
    rm -rf "$RAND_TMP"
    trap - EXIT
elif [[ $CONFIG == localconfig ]]; then
    # localconfig: running kernel's config as base — for daily-driver builds.
    # Requires CONFIG_IKCONFIG_PROC=y (provides /proc/config.gz). x86_64 only.
    if [[ $ARCH != x86_64 ]]; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=0\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$KERNEL_TREE" > "$STATUS_FILE"
        die "localconfig is only supported for x86_64 (sources /proc/config.gz from the running host kernel)"
    fi
    if [[ ! -r /proc/config.gz ]]; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=0\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$KERNEL_TREE" > "$STATUS_FILE"
        die "localconfig requires /proc/config.gz — enable CONFIG_IKCONFIG_PROC in your running kernel"
    fi
    zcat /proc/config.gz > "$PWD/$OUT_DIR/.config"
    if ! kmake olddefconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    fi
elif ! kmake "$CONFIG"; then
    printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
        "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
    die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
fi

# Step 1b: apply config fragment (skip for seed replay — fragment is already baked
# into the archived config; re-applying would overwrite options the original run set).
# KCONFIG_ALLCONFIG is NOT used here because some targets (e.g. tinyconfig)
# explicitly override it internally, silently discarding our fragment.
# Appending to .config + olddefconfig is reliable for every kernel target.
if [[ -z "${SEED_CONFIG:-}" ]] && [[ -f $FRAGMENT ]]; then
    info "Applying config fragment: $FRAGMENT"
    cat "$FRAGMENT" >> "$PWD/$OUT_DIR/.config"
    if ! kmake olddefconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config fragment failed: $FRAGMENT — see $LOG_FILE"
    fi
fi

# Step 1b.2: inject boot diagnostic modules when CANARY=1.
# Applied even for seed replay — the archived config won't have canary options,
# and the point of CANARY=1 replay is to diagnose why the archived config fails.
# Requires prior 'make canary-patch' to have patched the kernel tree.
CANARY_FRAGMENT="$SCRIPT_DIR/configs/canary.config"
if [[ "${CANARY:-0}" == 1 ]]; then
    info "Applying canary fragment (CANARY=1): $CANARY_FRAGMENT"
    cat "$CANARY_FRAGMENT" >> "$PWD/$OUT_DIR/.config"
    if ! kmake olddefconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Canary config fragment failed — run 'make canary-patch' first to add CONFIG_BOOT_CANARY to the kernel tree"
    fi
fi

# Step 1c: verify bootability floor for all bootable configs.
# configs/tinyconfig.config is the authoritative minimum: PRINTK, TTY + arch serial,
# initramfs, BINFMT_ELF/SCRIPT, TMPFS.  olddefconfig can silently drop these when a
# dependency chain changes between kernel versions.
# Only flag options that exist in this arch's Kconfig (disabled = problem;
# completely absent from .config = not supported by this arch, skip).
# Loop up to 3 passes: enabling a parent option (e.g. TTY) makes previously
# absent child options (e.g. SERIAL_AMBA_PL011) visible as disabled on the next pass.
BOOT_BASELINE="$SCRIPT_DIR/configs/tinyconfig.config"
CONFIG_CORRECTED=0
if ! is_build_only "$CONFIG" && [[ -f $BOOT_BASELINE ]]; then
    _correction_pass=0
    while [[ $_correction_pass -lt 3 ]]; do
        _correction_pass=$(( _correction_pass + 1 ))
        missing=()
        while IFS= read -r opt; do
            key="${opt%%=*}"
            if ! grep -q "^${key}=y" "$PWD/$OUT_DIR/.config"; then
                grep -q "^# ${key} is not set" "$PWD/$OUT_DIR/.config" \
                    && missing+=("$opt") || true
            fi
        done < <(grep '^CONFIG_[A-Z0-9_]*=y' "$BOOT_BASELINE")

        [[ ${#missing[@]} -eq 0 ]] && break

        warn "Boot baseline options missing (pass ${_correction_pass}) — auto-correcting: ${missing[*]}"
        printf '# boot-baseline-correction pass %d: %s\n' "$_correction_pass" "${missing[*]}" >> "$LOG_FILE"
        printf '%s\n' "${missing[@]}" >> "$PWD/$OUT_DIR/.config"
        if ! kmake olddefconfig; then
            printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
                "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
            die "Config correction failed (olddefconfig pass ${_correction_pass}): $CONFIG / $ARCH — see $LOG_FILE"
        fi
        still_missing=()
        for opt in "${missing[@]}"; do
            key="${opt%%=*}"
            grep -q "^${key}=y" "$PWD/$OUT_DIR/.config" || still_missing+=("$opt")
        done
        if [[ ${#still_missing[@]} -gt 0 ]]; then
            printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
                "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
            die "Boot baseline correction failed — still missing after olddefconfig: ${still_missing[*]} ($CONFIG / $ARCH)"
        fi
        CONFIG_CORRECTED=1
        info "Boot baseline corrected (pass ${_correction_pass}): ${missing[*]}"
    done
fi

# Fingerprint the final .config — config is now fully resolved
CONFIG_SHA256=$(sha256sum "$PWD/$OUT_DIR/.config" | awk '{print $1}')
info "Config SHA256: $CONFIG_SHA256 — $CONFIG / $ARCH"

# Step 2: build bzImage
# For build-only configs (allmodconfig, randconfig) the goal is catching
# compilation errors; bzImage covers the core kernel.
if [[ $BUILD_TIMEOUT -gt 0 ]]; then
    info "Building $KERNEL_IMAGE_NAME ($NPROC jobs, timeout ${BUILD_TIMEOUT}s) — $CONFIG / $ARCH"
else
    info "Building $KERNEL_IMAGE_NAME ($NPROC jobs) — $CONFIG / $ARCH"
fi
BUILD_EXIT=0
kmake --timed -j"$NPROC" "$KERNEL_IMAGE_NAME" || BUILD_EXIT=$?
if [[ $BUILD_EXIT -ne 0 ]]; then
    CONFIG_SHA256=$(sha256sum "$PWD/$OUT_DIR/.config" | awk '{print $1}')
    if [[ $BUILD_EXIT -eq 124 ]]; then
        printf 'STATUS=TIMEOUT\nSTART_TIME=%s\nDURATION=%d\nCONFIG_SHA256=%s\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$CONFIG_SHA256" "$KERNEL_TREE" > "$STATUS_FILE"
        [[ $CONFIG_CORRECTED -eq 1 ]] && printf 'CONFIG_CORRECTED=1\n' >> "$STATUS_FILE"
        die "Build timed out after ${BUILD_TIMEOUT}s: $CONFIG / $ARCH — see $LOG_FILE"
    fi
    printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nCONFIG_SHA256=%s\nKERNEL_TREE=%s\n' \
        "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$CONFIG_SHA256" "$KERNEL_TREE" > "$STATUS_FILE"
    [[ $CONFIG_CORRECTED -eq 1 ]] && printf 'CONFIG_CORRECTED=1\n' >> "$STATUS_FILE"
    die "Build failed: $CONFIG / $ARCH — see $LOG_FILE"
fi

CONFIG_SHA256=$(sha256sum "$PWD/$OUT_DIR/.config" | awk '{print $1}')
printf 'STATUS=PASS\nSTART_TIME=%s\nDURATION=%d\nCONFIG_SHA256=%s\nKERNEL_TREE=%s\n' \
    "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$CONFIG_SHA256" "$KERNEL_TREE" > "$STATUS_FILE"
[[ $CONFIG_CORRECTED -eq 1 ]] && printf 'CONFIG_CORRECTED=1\n' >> "$STATUS_FILE"
info "Build OK: $CONFIG / $ARCH"
