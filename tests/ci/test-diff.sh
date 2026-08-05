#!/bin/bash
# Tests for lib/diff.sh — regression/fix detection between two report dirs.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="$REPO/tests/ci/fixtures"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

RC1="$FIXTURES/reports/mainline-7.2-2026-01-01_10-00-00-v7.2-rc1"
RC2="$FIXTURES/reports/mainline-7.2-2026-01-02_10-00-00-v7.2-rc2"

# ── explicit OLD NEW — regression detected ────────────────────────────────────

begin_test "diff detects PASS→FAIL regression"
out=$("$REPO/lib/diff.sh" "$RC1" "$RC2" 2>&1) || true
assert_contains "$out" "REGRESSIONS" "regression header present"
assert_contains "$out" "tinyconfig/x86_64" "failing combo named"
assert_not_contains "$out" "defconfig/x86_64" "passing combo not listed"

# ── exit code 1 on regressions ────────────────────────────────────────────────

begin_test "diff exits 1 when regressions found"
assert_exit1 "exit-1-on-regression" "$REPO/lib/diff.sh" "$RC1" "$RC2"

# ── no regressions in same direction ─────────────────────────────────────────

begin_test "diff exits 0 when no regressions"
# rc1→rc1 is identical — nothing to report
assert_exit0 "exit-0-same-dir" "$REPO/lib/diff.sh" "$RC1" "$RC1"

# ── output file written when third arg provided ────────────────────────────────

begin_test "diff writes output file"
tmpdir; outfile="$_LAST_TMPDIR/diff.txt"
"$REPO/lib/diff.sh" "$RC1" "$RC2" "$outfile" 2>/dev/null || true
assert_file_exists "$outfile" "output file created"
out=$(cat "$outfile")
assert_contains "$out" "tinyconfig/x86_64" "regression in output file"

# ── FAIL→PASS fix detection ───────────────────────────────────────────────────

begin_test "diff detects FAIL→PASS fix"
out=$("$REPO/lib/diff.sh" "$RC2" "$RC1" 2>&1) || true
assert_contains "$out" "fix" "fix detected when swapped"

finish
