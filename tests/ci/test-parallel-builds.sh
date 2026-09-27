#!/bin/bash
# CI tests for the parallel build & test feature (feat/parallel-builds).
# Strategy: static analysis only — verify that the Makefile and lib/build.sh
# contain the expected structures.  No kernel or QEMU required.
#
# Tests:
#  1. PARALLEL_BUILDS / PARALLEL_VMS defined and exported in Makefile
#  2. _write_config_cache uses atomic tmp+mv for .config-base-commit (all 3 sites)
#  3. NPROC in build.sh respects PARALLEL_BUILDS
#  4. Build loop has two-tier structure with _flush between tiers
#  5. Initramfs and test loops use background-job pattern
#  6. PARALLEL_VMS guard in test loop
#  7. shellcheck clean
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

MK="$REPO/Makefile"
BUILD="$REPO/lib/build.sh"

# ── 1. Variable definitions ───────────────────────────────────────────────────

begin_test "Makefile: PARALLEL_BUILDS variable defined"
grep -q 'PARALLEL_BUILDS[[:space:]]*?=[[:space:]]*[0-9]' "$MK" \
    && pass "PARALLEL_BUILDS ?= N present" \
    || fail "PARALLEL_BUILDS ?= N not found in Makefile"

begin_test "Makefile: PARALLEL_VMS variable defined"
grep -q 'PARALLEL_VMS[[:space:]]*?=[[:space:]]*[0-9]' "$MK" \
    && pass "PARALLEL_VMS ?= N present" \
    || fail "PARALLEL_VMS ?= N not found in Makefile"

begin_test "Makefile: PARALLEL_BUILDS exported"
grep -q 'export.*PARALLEL_BUILDS' "$MK" \
    && pass "PARALLEL_BUILDS exported" \
    || fail "PARALLEL_BUILDS not in export line"

begin_test "Makefile: PARALLEL_VMS exported"
grep -q 'export.*PARALLEL_VMS' "$MK" \
    && pass "PARALLEL_VMS exported" \
    || fail "PARALLEL_VMS not in export line"

# ── 2. Atomic .config-base-commit write ──────────────────────────────────────

begin_test "build.sh: no bare redirect to _config_base_commit (all writes atomic)"
if grep -q 'printf.*TREE_COMMIT.*> "\$_config_base_commit"' "$BUILD"; then
    fail "bare redirect printf > \$_config_base_commit still present — must use tmp+mv"
else
    pass "no bare redirect to _config_base_commit found"
fi

begin_test "build.sh: _write_config_cache uses .tmp + mv for atomicity"
if grep -q '> "\${_config_base_commit}\.tmp"' "$BUILD"; then
    pass ".tmp + mv write found in build.sh"
else
    fail ".tmp + mv pattern not found in build.sh"
fi

begin_test "build.sh: all three _config_base_commit writes use atomic pattern"
bare_count=$(grep -c '"' "$BUILD" | head -1 || true)
bare_count=$(grep -c 'printf.*TREE_COMMIT.*> "\$_config_base_commit"' "$BUILD" 2>/dev/null || true)
atomic_count=$(grep -c '> "\${_config_base_commit}\.tmp"' "$BUILD" 2>/dev/null || true)
if [[ "$bare_count" -eq 0 && "$atomic_count" -ge 3 ]]; then
    pass "all $atomic_count write sites use .tmp+mv; 0 bare redirects"
elif [[ "$bare_count" -gt 0 ]]; then
    fail "$bare_count bare redirects remain; $atomic_count atomic sites"
else
    fail "expected ≥3 atomic write sites, found $atomic_count"
fi

# ── 3. NPROC respects PARALLEL_BUILDS ────────────────────────────────────────

begin_test "build.sh: NPROC computed using PARALLEL_BUILDS"
grep -q 'PARALLEL_BUILDS' "$BUILD" \
    && pass "PARALLEL_BUILDS referenced in build.sh" \
    || fail "PARALLEL_BUILDS not used in build.sh NPROC calculation"

begin_test "build.sh: NPROC has floor of 2 (prevents 1-job builds on low-core hosts)"
grep -q 'NPROC.*-lt 2.*NPROC=2\|NPROC=2.*-lt 2' "$BUILD" \
    && pass "NPROC floor >= 2 guard present" \
    || fail "no floor=2 guard found — on 4-core hosts with PARALLEL_BUILDS=4, NPROC would become 1"

# ── 4. Build tier structure ───────────────────────────────────────────────────
# Jobserver implementation: tier-0 and tier-1 are separate $(MAKE) invocations so
# the tier-0 barrier is enforced and the jobserver token pool is shared within each.

begin_test "Makefile: _TIER0_BASE defines tier-0 config list"
grep -q '_TIER0_BASE[[:space:]]*:=' "$MK" \
    && pass "tier-0 config list present in _TIER0_BASE" \
    || fail "_TIER0_BASE not found in Makefile"

begin_test "Makefile: build: invokes _tier0-build before _tier1-build"
tier0_line=$(grep -n '_tier0-build' "$MK" | grep '\$(MAKE)' | head -1 | cut -d: -f1)
tier1_line=$(grep -n '_tier1-build' "$MK" | grep '\$(MAKE)' | head -1 | cut -d: -f1)
if [[ -n "$tier0_line" && -n "$tier1_line" && "$tier0_line" -lt "$tier1_line" ]]; then
    pass "_tier0-build (L$tier0_line) before _tier1-build (L$tier1_line)"
else
    fail "could not verify tier0 (L${tier0_line:-?}) before tier1 (L${tier1_line:-?})"
fi

begin_test "Makefile: build: uses \$(MAKE) -j for parallel builds"
if grep -A 10 '^build:' "$MK" | grep -qE '\$\(MAKE\).*-j'; then
    pass "\$(MAKE) -j found in build target"
else
    fail "no \$(MAKE) -j in build target — builds may be sequential"
fi

# ── 5. Initramfs loop parallel pattern ───────────────────────────────────────

begin_test "Makefile: initramfs uses \$(MAKE) for parallel dispatch"
if grep -A 5 '^initramfs:' "$MK" | grep -q '\$(MAKE)'; then
    pass "\$(MAKE) dispatch found in initramfs target"
else
    fail "no \$(MAKE) in initramfs target"
fi

begin_test "Makefile: initramfs loop uses PARALLEL_BUILDS cap"
if grep -A 5 '^initramfs:' "$MK" | grep -q 'PARALLEL_BUILDS'; then
    pass "PARALLEL_BUILDS cap present in initramfs loop"
else
    fail "PARALLEL_BUILDS not used in initramfs loop"
fi

# ── 6. Test loop uses PARALLEL_VMS ───────────────────────────────────────────

begin_test "Makefile: test uses \$(MAKE) for parallel dispatch"
if grep -A 5 '^test:' "$MK" | grep -q '\$(MAKE)'; then
    pass "\$(MAKE) dispatch found in test target"
else
    fail "no \$(MAKE) in test target"
fi

begin_test "Makefile: test loop uses PARALLEL_VMS cap"
if grep -A 5 '^test:' "$MK" | grep -q 'PARALLEL_VMS'; then
    pass "PARALLEL_VMS cap present in test loop"
else
    fail "PARALLEL_VMS not used in test loop"
fi

begin_test "Makefile: test-% pattern preserves build.status SKIP check"
if grep -A 10 '^test-%:' "$MK" | grep -q 'bstatus.*PASS\|PASS.*bstatus'; then
    pass "build.status PASS check preserved in test-% pattern"
else
    fail "build.status PASS check missing from test-% pattern"
fi

# ── 7. Shellcheck ────────────────────────────────────────────────────────────

begin_test "shellcheck: test-parallel-builds.sh"
shellcheck --severity=warning "$REPO/tests/ci/test-parallel-builds.sh" \
    && pass "shellcheck clean" || fail "shellcheck errors"

finish
