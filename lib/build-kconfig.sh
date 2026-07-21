#!/bin/bash
# Exhaustive per-option build+boot sweep for a kernel subsystem.
# Enumerates all config/menuconfig entries from drivers/<SUBSYSTEM>/Kconfig,
# generates one .config per entry (tinyconfig + bootability fragment + that
# single option), builds and boots each through the full pipeline.
#
# Usage: called by 'make kconfig-build SUBSYSTEM=<name>'; not invoked directly.
# Required env: SUBSYSTEM, KERNEL_TREE, BUILD_DIR (exported by Makefile)
# Optional env: ARCHS, DRY_RUN, GATE_CFGS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/common.sh"

cd "$REPO_ROOT"

require_env SUBSYSTEM KERNEL_TREE BUILD_DIR

ARCHS_RAW=${ARCHS:-x86_64 i386 arm64}
DRY_RUN=${DRY_RUN:-0}
GATE_CFGS=${GATE_CFGS:-}
DRIVER=${DRIVER:-}
DRIVER=${DRIVER%.c}

FRAGMENT="$REPO_ROOT/configs/randkconfigconfig.config"
[[ -f "$FRAGMENT" ]] || die "bootability fragment not found: $FRAGMENT"

config_sym() { printf '%s' "${1^^}" | tr '-' '_'; }
SUBSYSTEM_SYM=$(config_sym "$SUBSYSTEM")

# Parse ARCHS into array
read -ra ARCHS_ARR <<< "$ARCHS_RAW"

# Parse GATE_CFGS into array
GATE_ARR=()
if [[ -n "$GATE_CFGS" ]]; then
    IFS=',' read -ra GATE_ARR <<< "$GATE_CFGS"
fi

# Enumerate all config symbols for this subsystem; filter to DRIVER= if set
ALL_OPTS=()
while IFS= read -r opt; do
    ALL_OPTS+=("$opt")
done < <("$REPO_ROOT/scripts/kconfig-enumerate.sh" "$SUBSYSTEM")

[[ ${#ALL_OPTS[@]} -gt 0 ]] || die "no config entries found in $KERNEL_TREE/drivers/$SUBSYSTEM/Kconfig"

if [[ -n "$DRIVER" ]]; then
    WANT="CONFIG_$(config_sym "$DRIVER")"
    OPTS=()
    for opt in "${ALL_OPTS[@]}"; do
        [[ $opt == "$WANT" ]] && OPTS+=("$opt")
    done
    [[ ${#OPTS[@]} -gt 0 ]] || die "$WANT not found in $KERNEL_TREE/drivers/$SUBSYSTEM/Kconfig"
else
    OPTS=("${ALL_OPTS[@]}")
fi

TOTAL=$(( ${#OPTS[@]} * ${#ARCHS_ARR[@]} ))

info "kconfig-build: subsystem=$SUBSYSTEM"
info "              kernel=$KERNEL_TREE"
info "              archs=${ARCHS_ARR[*]}"
[[ -n "$DRIVER" ]] && info "              driver=$DRIVER"
info "              options=${#OPTS[@]}"
info "              total builds=$TOTAL"
[[ -n "$GATE_CFGS" ]] && info "              gate=$GATE_CFGS"

# ── Dry run ───────────────────────────────────────────────────────────────────

if [[ $DRY_RUN -eq 1 ]]; then
    for opt in "${OPTS[@]}"; do
        for arch in "${ARCHS_ARR[@]}"; do
            printf '[DRY_RUN] %-40s %s\n' "$opt" "$arch"
        done
    done
    printf '[DRY_RUN] Total: %d configs × %d archs = %d builds\n' \
        "${#OPTS[@]}" "${#ARCHS_ARR[@]}" "$TOTAL"
    exit 0
fi

# ── Base config cache (tinyconfig + bootability fragment) per arch ─────────────

declare -A _BASE_TMP

_cleanup_bases() {
    local d
    for d in "${_BASE_TMP[@]+"${_BASE_TMP[@]}"}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup_bases EXIT

setup_base() {
    local arch=$1
    [[ -v _BASE_TMP[$arch] ]] && return 0

    local tmp cross_compile=""
    tmp=$(mktemp -d)

    [[ $arch == arm64 ]] && cross_compile="aarch64-linux-gnu-"

    if ! make -C "$KERNEL_TREE" O="$tmp" ARCH="$arch" \
            ${cross_compile:+CROSS_COMPILE="$cross_compile"} tinyconfig \
            >/dev/null 2>&1; then
        warn "base setup: tinyconfig failed for $arch — skipping arch"
        rm -rf "$tmp"
        _BASE_TMP[$arch]=""
        return 1
    fi

    cat "$FRAGMENT" >> "$tmp/.config"

    if ! make -C "$KERNEL_TREE" O="$tmp" ARCH="$arch" \
            ${cross_compile:+CROSS_COMPILE="$cross_compile"} olddefconfig \
            >/dev/null 2>&1; then
        warn "base setup: olddefconfig failed for $arch — skipping arch"
        rm -rf "$tmp"
        _BASE_TMP[$arch]=""
        return 1
    fi

    _BASE_TMP[$arch]=$tmp
    info "base config ready for $arch"
}

# Generate seed .config for (opt, arch) from the cached base; write to $out_path.
# Returns 1 if opt is absent from .config after olddefconfig (arch mismatch / bad deps).
generate_seed() {
    local opt=$1 arch=$2 out_path=$3
    local base="${_BASE_TMP[$arch]}" tmp cross_compile=""

    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf $tmp" RETURN

    cp "$base/.config" "$tmp/.config"

    [[ $arch == arm64 ]] && cross_compile="aarch64-linux-gnu-"

    local sc
    local enables=(--enable CONFIG_OF --enable CONFIG_COMPILE_TEST
                   --enable "CONFIG_$SUBSYSTEM_SYM" --enable "$opt")
    for sc in "${GATE_ARR[@]+"${GATE_ARR[@]}"}"; do
        enables+=(--enable "$sc")
    done

    "$KERNEL_TREE/scripts/config" --file "$tmp/.config" \
        "${enables[@]}" >/dev/null 2>&1 || true

    if ! make -C "$KERNEL_TREE" O="$tmp" ARCH="$arch" \
            ${cross_compile:+CROSS_COMPILE="$cross_compile"} olddefconfig \
            >/dev/null 2>&1; then
        return 1
    fi

    grep -q "^${opt}=y" "$tmp/.config" || return 1

    cp "$tmp/.config" "$out_path"
    trap - RETURN
    rm -rf "$tmp"
}

# ── Build initramfs once per arch ─────────────────────────────────────────────

for arch in "${ARCHS_ARR[@]}"; do
    if [[ ! -f "$BUILD_DIR/initramfs-$arch.cpio.gz" ]]; then
        info "Building initramfs for $arch"
        "$SCRIPT_DIR/initramfs.sh" "$arch"
    fi
done

# ── Main build+boot loop ───────────────────────────────────────────────────────

SEEDS_DIR="$BUILD_DIR/kconfig-build-seeds"
mkdir -p "$SEEDS_DIR"

PASS=0 FAIL=0 SKIP=0 N=0

for arch in "${ARCHS_ARR[@]}"; do
    if ! setup_base "$arch"; then
        for opt in "${OPTS[@]}"; do
            SKIP=$(( SKIP + 1 ))
        done
        continue
    fi

    for opt in "${OPTS[@]}"; do
        N=$(( N + 1 ))
        sym=${opt#CONFIG_}
        cfg_name="randkconfigconfig-$sym"
        seed="$SEEDS_DIR/$cfg_name-$arch.config"

        printf '[kconfig-build] [%d/%d] %-40s %s\n' "$N" "$TOTAL" "$opt" "$arch"

        if ! generate_seed "$opt" "$arch" "$seed"; then
            info "  SKIP — $opt absent after olddefconfig ($arch arch mismatch or unmet deps)"
            SKIP=$(( SKIP + 1 ))
            continue
        fi

        if ! SEED_CONFIG="$seed" "$SCRIPT_DIR/build.sh" "$cfg_name" "$arch"; then
            warn "  BUILD_FAIL — $opt $arch"
            FAIL=$(( FAIL + 1 ))
            continue
        fi

        bstatus=$(grep '^STATUS=' "$BUILD_DIR/$cfg_name-$arch/build.status" 2>/dev/null \
                  | cut -d= -f2 || echo UNKNOWN)
        if [[ $bstatus != PASS ]]; then
            warn "  BUILD_FAIL ($bstatus) — $opt $arch"
            FAIL=$(( FAIL + 1 ))
            continue
        fi

        if "$SCRIPT_DIR/vm.sh" "$cfg_name" "$arch"; then
            info "  PASS — $opt $arch"
            PASS=$(( PASS + 1 ))
        else
            warn "  BOOT/TEST FAIL — $opt $arch"
            FAIL=$(( FAIL + 1 ))
        fi
    done
done

info "kconfig-build complete: PASS=$PASS FAIL=$FAIL SKIP=$SKIP / ${#OPTS[@]} options × ${#ARCHS_ARR[@]} archs"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
