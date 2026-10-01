#!/bin/bash
# CI tests for lib/build.sh .build-active sentinel lifecycle.
# Verifies that .build-active is always cleaned up when build.sh exits,
# including after rand500config/kunitrandconfig RAND_TMP sections whose
# original "trap - EXIT" had cleared the main EXIT trap.
#
# Covers coverage-map paths:
#   I4: sentinel absent after pre-sentinel exit (bad arch)
#   I5: sentinel cleaned + LINKER= written by base EXIT trap (tinyconfig stub fail)
#   I6: rand500config compound trap cleans sentinel after make randconfig fail
#   I7: kunitrandconfig compound trap cleans sentinel after make randconfig fail
#
# Does not boot a kernel or need cross-compilers.  Requires ccache (installed
# by make bootstrap / CI apt-get).  Uses a minimal kernel Makefile stub that
# passes the "tree exists" guard but fails every real make invocation.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

if ! command -v ccache &>/dev/null; then
    printf 'skip  test-build-sentinel.sh: ccache not installed\n'
    exit 0
fi

# ── Shared helpers ─────────────────────────────────────────────────────────────

# Initialise an isolated ccache in $1/ccache; export CCACHE_DIR + CCACHE_MAX_SIZE.
setup_ccache_dir() {
    local base="$1"
    mkdir -p "$base/ccache"
    export CCACHE_DIR="$base/ccache"
    export CCACHE_MAX_SIZE="1M"
}

# Run build.sh; always exits 0 here (expected to fail; caller checks artifacts).
run_build_sh() {
    local config="$1" arch="$2" bd="$3"
    BUILD_DIR="$bd" CACHE_DIR="$bd/cache" RUN_STAMP="sentinel-ci-$(date +%s)" \
        bash "$REPO/lib/build.sh" "$config" "$arch" &>/dev/null || true
}

# ── I4: sentinel not written on pre-sentinel exit (bad arch) ──────────────────
# build.sh exits at the unsupported-arch die() on line ~40, before the sentinel
# write at line 64.  The sentinel file should never appear.

begin_test "build-sentinel-not-written-on-pre-sentinel-exit"
setup_kernel_tree
tmpdir; _bd="$_LAST_TMPDIR/build"
setup_ccache_dir "$_LAST_TMPDIR"
run_build_sh tinyconfig unsupported_arch_xyz "$_bd"
if [[ -f "$_bd/tinyconfig-unsupported_arch_xyz/.build-active" ]]; then
    fail "I4: .build-active unexpectedly written for unsupported arch"
else
    pass "I4: .build-active absent after pre-sentinel exit (bad arch)"
fi

# ── I5: sentinel cleaned up by base EXIT trap after post-sentinel failure ─────
# tinyconfig with a stub kernel fails at kmake tinyconfig (no Kbuild rules in
# stub).  The base EXIT trap (trap '_cleanup_sentinel' EXIT, set after line 64)
# must remove .build-active and append LINKER= to build.status.

begin_test "build-sentinel-cleaned-by-base-trap"
setup_kernel_tree
tmpdir; _bd="$_LAST_TMPDIR/build"
setup_ccache_dir "$_LAST_TMPDIR"
run_build_sh tinyconfig x86_64 "$_bd"

if [[ -f "$_bd/tinyconfig-x86_64/.build-active" ]]; then
    fail "I5: .build-active still present after build.sh exit (base EXIT trap did not run)"
else
    pass "I5: .build-active absent after post-sentinel failure (base trap cleaned up)"
fi
if grep -q '^LINKER=' "$_bd/tinyconfig-x86_64/build.status" 2>/dev/null; then
    pass "I5: LINKER= present in build.status — _cleanup_sentinel ran via base trap"
else
    fail "I5: LINKER= missing from build.status (base EXIT trap may not have called _cleanup_sentinel)"
fi

# ── I6: rand500config compound trap cleans sentinel ───────────────────────────
# Pre-populate the tinyconfig sibling so _try_sibling_base() returns 0 and
# build.sh skips kmake tinyconfig, reaching the RAND_TMP section.
# "make randconfig" then fails against the stub kernel, firing the compound
# EXIT trap which must include _cleanup_sentinel (the bug: original code used
# "trap 'rm -rf $RAND_TMP' EXIT" then "trap - EXIT", silently dropping it).

begin_test "build-sentinel-cleaned-by-rand500-compound-trap"
setup_kernel_tree
_commit=$(git -C "$KERNEL_TREE" rev-parse --short HEAD)
tmpdir; _bd="$_LAST_TMPDIR/build"
setup_ccache_dir "$_LAST_TMPDIR"

# Seed tinyconfig sibling so _try_sibling_base hits on the first check
mkdir -p "$_bd/tinyconfig-x86_64"
printf '# stub base config\n' > "$_bd/tinyconfig-x86_64/.config-base"
printf '%s\n' "$_commit"      > "$_bd/tinyconfig-x86_64/.config-base-commit"

run_build_sh rand500config x86_64 "$_bd"

if [[ -f "$_bd/rand500config-x86_64/.build-active" ]]; then
    fail "I6: .build-active still present (rand500 compound EXIT trap missing _cleanup_sentinel)"
else
    pass "I6: .build-active absent after rand500config RAND_TMP failure"
fi
if grep -q '^LINKER=' "$_bd/rand500config-x86_64/build.status" 2>/dev/null; then
    pass "I6: LINKER= present — _cleanup_sentinel called by rand500 compound trap"
else
    fail "I6: LINKER= missing (rand500 compound EXIT trap did not call _cleanup_sentinel)"
fi

# ── I7: kunitrandconfig compound trap cleans sentinel ────────────────────────
# Same as I6 but for kunitrandconfig, which uses defconfig as its sibling base.

begin_test "build-sentinel-cleaned-by-kunitrand-compound-trap"
setup_kernel_tree
_commit=$(git -C "$KERNEL_TREE" rev-parse --short HEAD)
tmpdir; _bd="$_LAST_TMPDIR/build"
setup_ccache_dir "$_LAST_TMPDIR"

# Seed defconfig sibling so _try_sibling_base hits; kunitrand never writes own cache
mkdir -p "$_bd/defconfig-x86_64"
printf '# stub base config\n' > "$_bd/defconfig-x86_64/.config-base"
printf '%s\n' "$_commit"      > "$_bd/defconfig-x86_64/.config-base-commit"

run_build_sh kunitrandconfig x86_64 "$_bd"

if [[ -f "$_bd/kunitrandconfig-x86_64/.build-active" ]]; then
    fail "I7: .build-active still present (kunitrand compound EXIT trap missing _cleanup_sentinel)"
else
    pass "I7: .build-active absent after kunitrandconfig RAND_TMP failure"
fi
if grep -q '^LINKER=' "$_bd/kunitrandconfig-x86_64/build.status" 2>/dev/null; then
    pass "I7: LINKER= present — _cleanup_sentinel called by kunitrand compound trap"
else
    fail "I7: LINKER= missing (kunitrand compound EXIT trap did not call _cleanup_sentinel)"
fi

finish
