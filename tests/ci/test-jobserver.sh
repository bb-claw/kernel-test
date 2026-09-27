#!/bin/bash
# CI tests for feat/jobserver-builds.
# Strategy: static analysis only — verify Makefile and lib/build.sh contain the
# expected structures. Tests FAIL before implementation, PASS after.
#
# Tests:
#  1. Makefile: build-$config-$arch per-combo target pattern defined
#  2. Makefile: top-level build uses $(MAKE) with -j$(nproc) (jobserver owner)
#  3. build.sh: no unconditional -jN in the bzImage kmake call
#  4. build.sh: --jobserver-auth detection in MAKEFLAGS
#  5. build.sh: fallback -j path for standalone / NO_JOBSERVER invocations
#  6. build.sh: NO_JOBSERVER escape hatch variable present
#  7. shellcheck clean
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

MK="$REPO/Makefile"
BUILD="$REPO/lib/build.sh"

# ── 1. Per-combo make targets ─────────────────────────────────────────────────

begin_test "Makefile: build-\$config-\$arch per-combo target pattern defined"
grep -q '^build-%:' "$MK" \
    && pass "build-% target present" \
    || fail "build-% target not found — per-combo make targets not implemented"

# ── 2. Top-level build uses jobserver token pool ──────────────────────────────

begin_test "Makefile: top-level build: uses \$(MAKE) with -j\$(nproc)"
if grep -A 5 '^build:' "$MK" | grep -qE '\$\(MAKE\).*nproc|\$\(MAKE\).*\$\(shell nproc\)'; then
    pass "\$(MAKE) -j\$(nproc) found in build target"
else
    fail "\$(MAKE) -j\$(nproc) not found in build target — jobserver token pool not owned by harness"
fi

# ── 3. No unconditional -jN in bzImage kmake call ────────────────────────────

begin_test "build.sh: no unconditional -j in bzImage kmake call"
# After implementation kmake is called with a variable (\$_build_j or similar),
# not a hardcoded -j"$NPROC". The -j only appears inside the fallback branch.
if grep -q 'kmake.*--timed.*-j.*NPROC\b\|kmake.*--timed.*-j[0-9"$]' "$BUILD"; then
    fail "unconditional -j\"\$NPROC\" still in bzImage kmake call — jobserver not wired up"
else
    pass "no unconditional -jN in kmake bzImage call"
fi

# ── 4. --jobserver-auth detection ────────────────────────────────────────────

begin_test "build.sh: --jobserver-auth detection in MAKEFLAGS"
grep -q 'jobserver-auth' "$BUILD" \
    && pass "--jobserver-auth detection present" \
    || fail "--jobserver-auth not detected in build.sh — jobserver inheritance not implemented"

# ── 5. Fallback -j$(nproc) for standalone invocations ────────────────────────

begin_test "build.sh: fallback -j path present for standalone / NO_JOBSERVER invocations"
grep -q '_build_j\|NPROC_ARG\|_job_flag' "$BUILD" \
    && pass "conditional job-count variable found" \
    || fail "no conditional job-count variable found — standalone build.sh would use -j1 without jobserver"

# ── 6. NO_JOBSERVER escape hatch ─────────────────────────────────────────────

begin_test "build.sh: NO_JOBSERVER escape hatch variable present"
grep -q 'NO_JOBSERVER' "$BUILD" \
    && pass "NO_JOBSERVER escape hatch present" \
    || fail "NO_JOBSERVER not found in build.sh — no escape hatch for hosts with incompatible make versions"

# ── 7. Shellcheck ─────────────────────────────────────────────────────────────

begin_test "shellcheck: test-jobserver.sh"
shellcheck --severity=warning "$REPO/tests/ci/test-jobserver.sh" \
    && pass "shellcheck clean" || fail "shellcheck errors"

finish
