#!/bin/bash
# CI tests for lib/build.sh error-path correctness.
# Verifies that INFRA_FAIL is written before early validation die()s,
# so a prior run's STATUS=PASS is never left in place when build.sh exits early.
# Covers coverage-map paths: I1 (bad arch), I2 (missing kernel tree), I3 (missing GCC).
# Does not require a real kernel tree, ccache, or cross-compilers.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Shared setup helpers ───────────────────────────────────────────────────────

# Create a minimal valid kernel-tree stub (just a Makefile — enough to pass the
# "Kernel Makefile not found" guard) and export KERNEL_TREE.
setup_kernel_stub() {
    tmpdir; local kt="$_LAST_TMPDIR"
    printf 'VERSION = 7\nPATCHLEVEL = 2\nSUBLEVEL = 0\nEXTRAVERSION = -rc99\nNAME = Test\n' \
        > "$kt/Makefile"
    KERNEL_TREE="$kt"; export KERNEL_TREE
}

# Run build.sh in a fresh isolated build dir; return its exit code.
# All required env vars must be exported before calling.
# Usage: run_build <config> <arch>
run_build() {
    tmpdir; local bd="$_LAST_TMPDIR/build"
    local cache_dir="$_LAST_TMPDIR/cache"
    mkdir -p "$bd" "$cache_dir"
    BUILD_DIR="$bd" CACHE_DIR="cache" RUN_STAMP="test-$(date +%s)" \
        bash "$REPO/lib/build.sh" "$1" "$2" &>/dev/null
}

# Assert build.status for <config>/<arch> in the last run_build's BUILD_DIR.
# Reads STATUS= from the file that run_build would have created.
# Since run_build uses _LAST_TMPDIR, caller must capture it beforehand.
status_of() {
    local bd="$1" config="$2" arch="$3"
    grep '^STATUS=' "$bd/$config-$arch/build.status" 2>/dev/null | cut -d= -f2
}

# ── Test I1: unsupported arch → INFRA_FAIL written, exits non-zero ─────────────

begin_test "build-sh-bad-arch-writes-infra-fail"

setup_kernel_stub
tmpdir; _I1_BD="$_LAST_TMPDIR/build"; mkdir -p "$_I1_BD"

if BUILD_DIR="$_I1_BD" CACHE_DIR="cache" RUN_STAMP="test-i1" \
        bash "$REPO/lib/build.sh" tinyconfig unsupported_arch_xyz &>/dev/null; then
    fail "build.sh should exit non-zero for unsupported arch"
else
    pass "build.sh exits non-zero for unsupported arch"
fi

_i1_status=$(grep '^STATUS=' "$_I1_BD/tinyconfig-unsupported_arch_xyz/build.status" \
    2>/dev/null | cut -d= -f2 || true)
if [[ $_i1_status == INFRA_FAIL ]]; then
    pass "build.status contains INFRA_FAIL after bad arch die()"
else
    fail "expected INFRA_FAIL in build.status after bad arch die(), got '${_i1_status:-<missing>}'"
fi

# Also verify: if a prior STATUS=PASS exists, it is overwritten by INFRA_FAIL.
tmpdir; _I1_STALE="$_LAST_TMPDIR/build"
mkdir -p "$_I1_STALE/tinyconfig-unsupported_arch_xyz"
printf 'STATUS=PASS\n' > "$_I1_STALE/tinyconfig-unsupported_arch_xyz/build.status"

if BUILD_DIR="$_I1_STALE" CACHE_DIR="cache" RUN_STAMP="test-i1-stale" \
        bash "$REPO/lib/build.sh" tinyconfig unsupported_arch_xyz &>/dev/null; then
    fail "build.sh should exit non-zero (stale-status test)"
else
    _stale=$(grep '^STATUS=' "$_I1_STALE/tinyconfig-unsupported_arch_xyz/build.status" \
        2>/dev/null | cut -d= -f2 || true)
    if [[ $_stale == INFRA_FAIL ]]; then
        pass "stale STATUS=PASS overwritten with INFRA_FAIL"
    else
        fail "stale STATUS=PASS not overwritten; got '${_stale:-<missing>}'"
    fi
fi

# ── Test I2: missing kernel tree → INFRA_FAIL written, exits non-zero ──────────

begin_test "build-sh-missing-kernel-tree-writes-infra-fail"

tmpdir; _I2_BD="$_LAST_TMPDIR/build"; mkdir -p "$_I2_BD"

if KERNEL_TREE="/nonexistent-kernel-tree-abc123" \
        BUILD_DIR="$_I2_BD" CACHE_DIR="cache" RUN_STAMP="test-i2" \
        bash "$REPO/lib/build.sh" tinyconfig x86_64 &>/dev/null; then
    fail "build.sh should exit non-zero for missing kernel tree"
else
    pass "build.sh exits non-zero for missing kernel tree"
fi

_i2_status=$(grep '^STATUS=' "$_I2_BD/tinyconfig-x86_64/build.status" \
    2>/dev/null | cut -d= -f2 || true)
if [[ $_i2_status == INFRA_FAIL ]]; then
    pass "build.status contains INFRA_FAIL after missing-kernel-tree die()"
else
    fail "expected INFRA_FAIL after missing kernel tree, got '${_i2_status:-<missing>}'"
fi

# ── Test I3: missing host compiler → INFRA_FAIL written, exits non-zero ────────

begin_test "build-sh-missing-gcc-writes-infra-fail"

setup_kernel_stub
tmpdir; _I3_BD="$_LAST_TMPDIR/build"; mkdir -p "$_I3_BD"

if KERNEL_TREE="$KERNEL_TREE" GCC="nonexistent-gcc-ci-test-xyz" \
        BUILD_DIR="$_I3_BD" CACHE_DIR="cache" RUN_STAMP="test-i3" \
        bash "$REPO/lib/build.sh" tinyconfig x86_64 &>/dev/null; then
    fail "build.sh should exit non-zero for missing GCC"
else
    pass "build.sh exits non-zero for missing GCC"
fi

_i3_status=$(grep '^STATUS=' "$_I3_BD/tinyconfig-x86_64/build.status" \
    2>/dev/null | cut -d= -f2 || true)
if [[ $_i3_status == INFRA_FAIL ]]; then
    pass "build.status contains INFRA_FAIL after missing-GCC die()"
else
    fail "expected INFRA_FAIL after missing GCC, got '${_i3_status:-<missing>}'"
fi

finish
