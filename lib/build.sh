#!/bin/bash
# Build one (config, arch) pair out-of-tree using ccache.
# Usage: build.sh <config> <arch>
# Writes build/<config>-<arch>/build.status: PASS | FAIL
set -euo pipefail
. "$(dirname "$0")/common.sh"

CONFIG=${1:?usage: build.sh <config> <arch>}
ARCH=${2:?usage: build.sh <config> <arch>}
info "Starting build"

require_env KERNEL_TREE BUILD_DIR CACHE_DIR RUN_STAMP
BUILD_TIMEOUT=${BUILD_TIMEOUT:-600}
GCC=${GCC:-gcc}         # override with e.g. GCC=gcc-15 for older stable kernels
USE_LLD=${USE_LLD:-1}

# ── Architecture-specific settings ───────────────────────────────────────────

CROSS_COMPILE=$(arch_cross_compile "$ARCH")
KERNEL_IMAGE_NAME=$(arch_kernel_image "$ARCH")
case "$ARCH" in
    x86_64|i386)
        KERNEL_CC="$GCC"
        ;;
    arm64|riscv)
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

# Catch a missing host compiler before ccache tries (and fails obscurely) to invoke it
command -v "$GCC" >/dev/null 2>&1 || \
    die "Host compiler '$GCC' not found in PATH — override via GCC= in local.mk (e.g. GCC=gcc)"

OUT_DIR="$BUILD_DIR/$CONFIG-$ARCH"
LOG_FILE="$OUT_DIR/build.log"
STATUS_FILE="$OUT_DIR/build.status"
_host_cpus=$(nproc 2>/dev/null || echo 1)
NPROC=$(( _host_cpus / ${PARALLEL_BUILDS:-1} ))
[[ $NPROC -lt 2 ]] && NPROC=2

# GNU make jobserver detection (make ≥4.2: fifo:/path survives exec() boundary).
# When active: omit -j so kernel make inherits the shared token pool; stragglers
# absorb freed tokens automatically as sibling builds finish.
# NO_JOBSERVER=1 or no --jobserver-auth in MAKEFLAGS → static -j fallback.
if [[ "${NO_JOBSERVER:-0}" != 1 && "${MAKEFLAGS:-}" == *--jobserver-auth* ]]; then
    _build_j=()
else
    _build_j=("-j$NPROC")
fi

mkdir -p "$OUT_DIR"
: > "$LOG_FILE"
rm -f "$OUT_DIR/vm.status"   # clear stale test results so a failed build never shows old PASS data
printf 'STATUS=INFRA_FAIL\n' > "$STATUS_FILE"  # sentinel: overwritten on success; prevents stale STATUS=PASS if build.sh dies before the first config step

# ── Linker selection ──────────────────────────────────────────────────────────
LINKER=bfd
LINKER_OBJCOPY=""
if detect_lld; then
    LINKER=lld
    info "Linker: ld.lld ${LLD_VERSION}"
    command -v llvm-objcopy >/dev/null 2>&1 && LINKER_OBJCOPY="llvm-objcopy"
fi
trap 'printf "LINKER=%s\n" "${LINKER:-bfd}" >> "${STATUS_FILE}"' EXIT

# ── Kernel source identity ────────────────────────────────────────────────────

TREE_TAG=$(git -C "$KERNEL_TREE" describe --exact-match HEAD 2>/dev/null \
           || read_kernel_makefile_version \
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

# Apply size and tuning from Makefile variables (overridable via local.mk).
# All settings written to ccache.conf so they persist for standalone ccache commands.
ccache --set-config="max_size=${CCACHE_MAX_SIZE:-25G}"
if [[ "${CCACHE_TUNE:-1}" == "1" ]]; then
    ccache --set-config="sloppiness=time_macros"  # ignore __DATE__/__TIME__ in cache key
    ccache --set-config="compression_level=1"     # zstd level 1: faster on NVMe, ~5% larger
    ccache --set-config="base_dir=$HOME"           # normalize absolute paths in cache keys
else
    ccache --set-config="sloppiness="
    ccache --set-config="compression_level=0"
    ccache --set-config="base_dir="
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Namespace variant: derive base config ─────────────────────────────────────
# Configs like tinynsconfig, defnsconfig, rand500nsconfig are base configs with
# configs/namespaces.config appended.  Strip the 'ns' infix to get the base.
NS_BASE=""
case "$CONFIG" in
    tinynsconfig)      NS_BASE=tinyconfig ;;
    defnsconfig)       NS_BASE=defconfig ;;
    kunitnsconfig)     NS_BASE=kunitconfig ;;
    kunitrandnsconfig) NS_BASE=kunitrandconfig ;;
    randnsconfig)      NS_BASE=randconfig ;;
    rand500nsconfig)   NS_BASE=rand500config ;;
    randdefnsconfig)   NS_BASE=randdefconfig ;;
esac
EFFECTIVE_CONFIG="${NS_BASE:-$CONFIG}"

FRAGMENT="$SCRIPT_DIR/configs/${EFFECTIVE_CONFIG}.config"

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
    if [[ ${LINKER:-bfd} == lld ]]; then
        if [[ -n "${LINKER_OBJCOPY:-}" ]]; then
            make_args+=( LD=ld.lld OBJCOPY="$LINKER_OBJCOPY" )
        elif [[ "$ARCH" == x86_64 || "$ARCH" == i386 ]]; then
            make_args+=( LD=ld.lld )
        fi
    fi
    if [[ ${V:-0} == 1 ]]; then
        "${pfx[@]}" make "${make_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    else
        "${pfx[@]}" make "${make_args[@]}" >> "$LOG_FILE" 2>&1
    fi
}

BUILD_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD_START_EPOCH=$(date -u +%s)

# ── Config cache setup ────────────────────────────────────────────────────────
# Deterministic configs produce identical .config output for a given kernel
# commit + fragment set.  Cache the pre-fragment base so repeated runs of the
# same kernel version skip the slow kmake step (29 s for tinyconfig/riscv).
# Cache key: kernel commit + sha256 of each fragment/overlay that exists.
# Files written per combo: .config-base (pre-fragment snapshot),
#   .config-base-commit (plain commit hash, for cross-combo lookups),
#   .config-cache-hash (full opaque key for this combo's fragment set).
_config_base="$OUT_DIR/.config-base"
_config_base_commit="$OUT_DIR/.config-base-commit"
_config_cache_hash="$OUT_DIR/.config-cache-hash"
_cache_frags=()
[[ -f "$FRAGMENT" ]] && _cache_frags+=("$FRAGMENT")
_early_overlay="$SCRIPT_DIR/configs/${EFFECTIVE_CONFIG}-${ARCH}.config"
[[ -f "$_early_overlay" ]] && _cache_frags+=("$_early_overlay")
_ns_fragment_path="$SCRIPT_DIR/configs/namespaces.config"
[[ -n "${NS_BASE:-}" && -f "$_ns_fragment_path" ]] && _cache_frags+=("$_ns_fragment_path")

# _try_config_cache: restore .config-base and return 0 on a valid cache hit.
_try_config_cache() {
    [[ "${NO_CONFIG_CACHE:-0}" == "1" ]] && return 1
    [[ -f "$_config_base" ]] || return 1
    config_cache_valid "$_config_cache_hash" "$TREE_COMMIT" "${_cache_frags[@]}" || return 1
    cp "$_config_base" "$OUT_DIR/.config"
    info "Config cache hit: $CONFIG / $ARCH (skipping kmake)"
    return 0
}

# _write_config_cache: snapshot .config as the new base and update the stamp.
_write_config_cache() {
    cp "$OUT_DIR/.config" "$_config_base"
    printf '%s\n' "$TREE_COMMIT" > "${_config_base_commit}.tmp" && mv "${_config_base_commit}.tmp" "$_config_base_commit"
    config_cache_hash "$TREE_COMMIT" "${_cache_frags[@]}" > "$_config_cache_hash"
}

# _try_sibling_base <dir>: copy a sibling combo's pre-fragment .config-base when
# the kernel commit matches, avoiding a redundant kmake scan.  Returns 0 on hit.
#
# CORRECTNESS INVARIANT — callers must follow this rule:
#   Deterministic configs (kunitconfig, tinynsconfig, defnsconfig, vf2config …):
#     call _write_config_cache after a 0 return so the per-combo cache is warm
#     for subsequent runs and the sibling is never consulted again.
#   Random configs (rand500config, randdefconfig, kunitrandconfig …):
#     do NOT call _write_config_cache — their final .config changes every run,
#     so a per-combo cache entry would be immediately stale.
_try_sibling_base() {
    local sib_dir="$1"
    [[ "${NO_CONFIG_CACHE:-0}" == "1" ]] && return 1
    [[ -f "$sib_dir/.config-base-commit" ]] || return 1
    [[ "$(cat "$sib_dir/.config-base-commit")" == "$TREE_COMMIT" ]] || return 1
    [[ -f "$sib_dir/.config-base" ]] || return 1
    cp "$sib_dir/.config-base" "$OUT_DIR/.config"
    local sib_name; sib_name=$(basename "$sib_dir" | sed 's/-[^-]*$//')
    info "Config cache hit (sibling: $sib_name): $CONFIG / $ARCH"
    return 0
}

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
elif [[ $EFFECTIVE_CONFIG == rand500config ]]; then
    # Base: tinyconfig (tiny, known-bootable kernel).
    # Random config: never write own per-combo cache (output changes each run).
    # Priority: tinyconfig sibling → own prior base → fresh kmake.
    _tiny_sib="$BUILD_DIR/tinyconfig-$ARCH"
    if _try_sibling_base "$_tiny_sib"; then
        :
    elif [[ "${NO_CONFIG_CACHE:-0}" != "1" ]] && \
         [[ -f "$_config_base_commit" ]] && \
         [[ "$(cat "$_config_base_commit")" == "$TREE_COMMIT" ]] && \
         [[ -f "$_config_base" ]]; then
        info "Config cache hit (own base): $CONFIG / $ARCH"
        cp "$_config_base" "$OUT_DIR/.config"
    else
        if ! kmake tinyconfig; then
            printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
                "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
            die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
        fi
        cp "$OUT_DIR/.config" "$_config_base"
        printf '%s\n' "$TREE_COMMIT" > "${_config_base_commit}.tmp" && mv "${_config_base_commit}.tmp" "$_config_base_commit"
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
elif [[ $EFFECTIVE_CONFIG == randdefconfig ]]; then
    # Base: defconfig (broad, coherent, realistic baseline).
    # Random config: never write own per-combo cache (output changes each run).
    # Priority: defconfig sibling → own prior base → fresh kmake.
    _def_sib="$BUILD_DIR/defconfig-$ARCH"
    if _try_sibling_base "$_def_sib"; then
        :
    elif [[ "${NO_CONFIG_CACHE:-0}" != "1" ]] && \
         [[ -f "$_config_base_commit" ]] && \
         [[ "$(cat "$_config_base_commit")" == "$TREE_COMMIT" ]] && \
         [[ -f "$_config_base" ]]; then
        info "Config cache hit (own base): $CONFIG / $ARCH"
        cp "$_config_base" "$OUT_DIR/.config"
    else
        if ! kmake defconfig; then
            printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
                "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
            die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
        fi
        cp "$OUT_DIR/.config" "$_config_base"
        printf '%s\n' "$TREE_COMMIT" > "${_config_base_commit}.tmp" && mv "${_config_base_commit}.tmp" "$_config_base_commit"
    fi
    # Randomly disable ~300 options to reduce build surface.
    # The fragment (step 1b) forces heavy subsystems off and re-pins bootability options,
    # so olddefconfig resolves any cascading conflicts safely.
    grep '^CONFIG_[A-Z0-9_]*=[ym]$' "$PWD/$OUT_DIR/.config" | shuf -n 300 \
        | sed 's/=[ym]$/=n/' > "$OUT_DIR/randdef-disabled.config"
    cat "$OUT_DIR/randdef-disabled.config" >> "$PWD/$OUT_DIR/.config"
elif [[ $EFFECTIVE_CONFIG == kunitconfig ]]; then
    # kunitconfig / kunitnsconfig: defconfig base + KUnit suites (applied in step 1b).
    # Deterministic: write own cache after any miss so warm runs never need the sibling.
    if _try_config_cache; then
        :
    elif _try_sibling_base "$BUILD_DIR/defconfig-$ARCH"; then
        _write_config_cache
    elif ! kmake defconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    else
        _write_config_cache
    fi
elif [[ $EFFECTIVE_CONFIG == kunitrandconfig ]]; then
    # Enumerate every CONFIG_*KUNIT* from a fresh randconfig (full option set for
    # this arch), append to defconfig base.  olddefconfig (step 1b) drops any
    # module whose deps are unmet — only valid, buildable options survive.
    # Random config: never write own per-combo cache (output changes each run).
    # Priority: defconfig sibling → fresh kmake (no own-base fallback: kunitrand
    # never writes its own base, so a stale commit file cannot exist).
    _def_sib="$BUILD_DIR/defconfig-$ARCH"
    if ! _try_sibling_base "$_def_sib"; then
        if ! kmake defconfig; then
            printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
                "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
            die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
        fi
    fi
    RAND_TMP=$(mktemp -d)
    trap 'rm -rf "$RAND_TMP"' EXIT
    make -C "$KERNEL_TREE" O="$RAND_TMP" ARCH="$ARCH" \
        KBUILD_BUILD_TIMESTAMP="$RUN_STAMP" randconfig >> "$LOG_FILE" 2>&1
    # Force =m → =y: initramfs cannot load modules, tests must be built-in.
    grep '^CONFIG_[A-Z0-9_]*KUNIT[A-Z0-9_]*=[ym]$' "$RAND_TMP/.config" \
        | sed 's/=[ym]$/=y/' \
        | tee "$OUT_DIR/kunitrand-sampled.config" >> "$PWD/$OUT_DIR/.config" || true
    rm -rf "$RAND_TMP"
    trap - EXIT
elif [[ $EFFECTIVE_CONFIG == vf2config ]]; then
    # vf2config: StarFive JH7110 (VisionFive 2) — riscv-only; uses defconfig as base.
    # Deterministic: write own cache after any miss so warm runs never need the sibling.
    if [[ $ARCH != riscv ]]; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=0\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$KERNEL_TREE" > "$STATUS_FILE"
        die "vf2config is riscv-only (StarFive JH7110 SoC) — use ARCHS=riscv"
    fi
    if _try_config_cache; then
        :
    elif _try_sibling_base "$BUILD_DIR/defconfig-$ARCH"; then
        _write_config_cache
    elif ! kmake defconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    else
        _write_config_cache
    fi
elif [[ $EFFECTIVE_CONFIG == localconfig ]]; then
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
elif [[ $EFFECTIVE_CONFIG == tinyconfig && -n $NS_BASE ]]; then
    # tinynsconfig: tinyconfig base + namespaces.config (applied in step 1b).
    # Deterministic: write own cache after any miss so warm runs never need the sibling.
    if _try_config_cache; then
        :
    elif _try_sibling_base "$BUILD_DIR/tinyconfig-$ARCH"; then
        _write_config_cache
    elif ! kmake tinyconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    else
        _write_config_cache
    fi
elif [[ $EFFECTIVE_CONFIG == defconfig && -n $NS_BASE ]]; then
    # defnsconfig: defconfig base + namespaces.config (applied in step 1b).
    # Deterministic: write own cache after any miss so warm runs never need the sibling.
    if _try_config_cache; then
        :
    elif _try_sibling_base "$BUILD_DIR/defconfig-$ARCH"; then
        _write_config_cache
    elif ! kmake defconfig; then
        printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
            "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
        die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
    else
        _write_config_cache
    fi
elif _try_config_cache; then
    :
elif ! kmake "$EFFECTIVE_CONFIG"; then
    printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
        "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
    die "Config step failed: $CONFIG / $ARCH — see $LOG_FILE"
else
    _write_config_cache
fi

# Step 1b: apply config fragment + arch overlay, then resolve with one olddefconfig.
# Skip for seed replay — the archived config already has both baked in.
# KCONFIG_ALLCONFIG is NOT used because some targets (e.g. tinyconfig) override it
# internally, silently discarding our fragment.  cat >> .config is reliable for all.
ARCH_OVERLAY="$SCRIPT_DIR/configs/${EFFECTIVE_CONFIG}-${ARCH}.config"
NS_FRAGMENT="$SCRIPT_DIR/configs/namespaces.config"
if [[ -z "${SEED_CONFIG:-}" ]]; then
    _applied=0
    if [[ -f $FRAGMENT ]]; then
        info "Applying config fragment: $FRAGMENT"
        cat "$FRAGMENT" >> "$PWD/$OUT_DIR/.config"
        _applied=1
    fi
    if [[ -n $NS_BASE && -f $NS_FRAGMENT ]]; then
        info "Applying namespace fragment: $NS_FRAGMENT"
        cat "$NS_FRAGMENT" >> "$PWD/$OUT_DIR/.config"
        _applied=1
    fi
    if [[ -f "$ARCH_OVERLAY" ]]; then
        info "Applying arch overlay: $ARCH_OVERLAY"
        cat "$ARCH_OVERLAY" >> "$PWD/$OUT_DIR/.config"
        _applied=1
    fi
    if [[ $_applied -eq 1 ]]; then
        if ! kmake olddefconfig; then
            printf 'STATUS=FAIL\nSTART_TIME=%s\nDURATION=%d\nKERNEL_TREE=%s\n' \
                "$BUILD_START_TIME" "$(( $(date -u +%s) - BUILD_START_EPOCH ))" "$KERNEL_TREE" > "$STATUS_FILE"
            die "Config fragment/overlay failed: $CONFIG/$ARCH — see $LOG_FILE"
        fi
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
# olddefconfig can silently drop required options when a dependency chain changes
# between kernel versions.  Arch-specific serial/FPU options are now owned by
# the arch overlay (configs/<profile>-<arch>.config) and excluded here to avoid
# duplication.  Only arch-neutral options that apply identically on every arch.
# Only flag options that exist in this arch's Kconfig (disabled = problem;
# completely absent from .config = not supported by this arch, skip).
# Loop up to 3 passes: enabling a parent (e.g. TTY) makes previously absent
# children visible as disabled on the next pass.
BOOT_BASELINE_OPTS=(
    CONFIG_PRINTK=y
    CONFIG_TTY=y
    CONFIG_BLK_DEV_INITRD=y
    CONFIG_RD_GZIP=y
    CONFIG_BINFMT_ELF=y
    CONFIG_BINFMT_SCRIPT=y
    CONFIG_TMPFS=y
)
CONFIG_CORRECTED=0
if ! is_build_only "$EFFECTIVE_CONFIG"; then
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
        done < <(printf '%s\n' "${BOOT_BASELINE_OPTS[@]}")

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
_build_j_desc=${_build_j[0]:+${_build_j[0]#-j} jobs}; _build_j_desc=${_build_j_desc:-jobserver}
if [[ $BUILD_TIMEOUT -gt 0 ]]; then
    info "Building $KERNEL_IMAGE_NAME ($_build_j_desc, timeout ${BUILD_TIMEOUT}s) — $CONFIG / $ARCH"
else
    info "Building $KERNEL_IMAGE_NAME ($_build_j_desc) — $CONFIG / $ARCH"
fi
BUILD_EXIT=0
kmake --timed "${_build_j[@]}" "$KERNEL_IMAGE_NAME" || BUILD_EXIT=$?
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
