#!/bin/bash
# Preflight checks for the kernel-test pipeline.
# Called automatically by make build/make all; also available as make preflight.
# Usage: preflight.sh
# Exports required: GCC ARCHS BUILD_DIR CACHE_DIR (all have Makefile defaults).
# Exits 0 when all checks pass; exits 1 and prints actionable errors otherwise.
set -euo pipefail
. "$(dirname "$0")/common.sh"

GCC=${GCC:-gcc}
USE_LLD=${USE_LLD:-1}
ARCHS=${ARCHS:-x86_64 i386 arm64 riscv}
BUILD_DIR=${BUILD_DIR:-build}
CACHE_DIR=${CACHE_DIR:-cache}
MIN_BUILD_SPACE_GB=${MIN_BUILD_SPACE_GB:-5}
MIN_CACHE_SPACE_GB=${MIN_CACHE_SPACE_GB:-5}

_errors=0
_check_fail() { printf 'ERROR: %s\n' "$*" >&2; _errors=$(( _errors + 1 )); }

# ── Host compiler ─────────────────────────────────────────────────────────────
command -v "$GCC" >/dev/null 2>&1 || \
    _check_fail "Host compiler '$GCC' not found in PATH — set GCC= in local.mk (e.g. GCC=gcc)"

# ── Cross-compilers and QEMU binaries per arch ────────────────────────────────
for _arch in $ARCHS; do
    case "$_arch" in
        arm64)
            command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || \
                _check_fail "Cross-compiler 'aarch64-linux-gnu-gcc' not found for arch arm64 — run: make bootstrap"
            command -v qemu-system-aarch64 >/dev/null 2>&1 || \
                _check_fail "QEMU binary 'qemu-system-aarch64' not found for arch arm64 — run: make bootstrap"
            ;;
        riscv)
            command -v riscv64-linux-gnu-gcc >/dev/null 2>&1 || \
                _check_fail "Cross-compiler 'riscv64-linux-gnu-gcc' not found for arch riscv — run: make bootstrap"
            command -v qemu-system-riscv64 >/dev/null 2>&1 || \
                _check_fail "QEMU binary 'qemu-system-riscv64' not found for arch riscv — run: make bootstrap"
            ;;
        x86_64)
            command -v qemu-system-x86_64 >/dev/null 2>&1 || \
                _check_fail "QEMU binary 'qemu-system-x86_64' not found for arch x86_64 — run: make bootstrap"
            ;;
        i386)
            command -v qemu-system-i386 >/dev/null 2>&1 || \
                _check_fail "QEMU binary 'qemu-system-i386' not found for arch i386 — run: make bootstrap"
            ;;
        *) _check_fail "Unknown arch '$_arch' in ARCHS" ;;
    esac
done

# ── Disk space ────────────────────────────────────────────────────────────────
_check_space() {
    local dir="$1" min_gb="$2" label="$3"
    mkdir -p "$dir"
    local avail_gb
    avail_gb=$(df -BG "$dir" | awk 'NR==2 { gsub(/G/, "", $4); print $4 + 0 }')
    [[ "$avail_gb" -ge "$min_gb" ]] || \
        _check_fail "$label ($dir) has ${avail_gb}G free, need ${min_gb}G — free space or set MIN_BUILD_SPACE_GB / MIN_CACHE_SPACE_GB in local.mk"
}
_check_space "$BUILD_DIR" "$MIN_BUILD_SPACE_GB" "BUILD_DIR"
_check_space "$CACHE_DIR" "$MIN_CACHE_SPACE_GB" "CACHE_DIR"

# ── LLD linker (informational) ────────────────────────────────────────────────
if [[ "$USE_LLD" != "0" ]]; then
    if detect_lld; then
        printf 'Preflight: LLD %s ≥ %s — using ld.lld\n' "$LLD_VERSION" "$LLD_MIN"
    elif [[ -n "$LLD_VERSION" ]]; then
        printf 'Preflight: LLD %s < %s — using BFD (upgrade lld or set USE_LLD=0 in local.mk)\n' \
            "$LLD_VERSION" "$LLD_MIN"
    else
        printf 'Preflight: ld.lld not found — using BFD\n'
    fi
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $_errors -gt 0 ]]; then
    printf 'Preflight: %d error(s) — fix the above before building\n' "$_errors" >&2
    exit 1
fi
printf 'Preflight: all checks passed\n'
