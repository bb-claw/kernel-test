#!/bin/bash
# CI tests for feat/run-metrics.
# Strategy: static analysis + functional tests with fixtures.
# Tests FAIL before implementation, PASS after.
#
# Tests:
#  1. lib/metrics.sh is shellcheck clean
#  2. lib/monitor.sh is shellcheck clean
#  3. metrics.sh with fixture data produces a well-formed metrics.txt
#  4. metrics.txt contains all required fields
#  5. Required numeric fields are non-negative integers
#  6. BUILD_WALL_TIME is consistent with per-combo times (wall ≥ max individual time)
#  7. monitor.sh --once runs and produces expected section headers
#  8. .build-active sentinel is created/removed by build.sh EXIT trap (static check)
#  9. .vm-active sentinel is created/removed by vm.sh (static check)
# 10. Makefile has monitor target and ccache snapshot step
# 11. report.sh calls metrics.sh
# 12. shellcheck: test-metrics.sh itself
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

METRICS="$REPO/lib/metrics.sh"
MONITOR="$REPO/lib/monitor.sh"
MK="$REPO/Makefile"
BUILD_SH="$REPO/lib/build.sh"
VM_SH="$REPO/lib/vm.sh"
REPORT_SH="$REPO/lib/report.sh"
FIX="$REPO/tests/ci/fixtures/metrics"

# ── 1. shellcheck: lib/metrics.sh ────────────────────────────────────────────

begin_test "shellcheck: lib/metrics.sh"
shellcheck --severity=warning "$METRICS" \
    && pass "shellcheck clean" || fail "shellcheck errors"

# ── 2. shellcheck: lib/monitor.sh ────────────────────────────────────────────

begin_test "shellcheck: lib/monitor.sh"
shellcheck --severity=warning "$MONITOR" \
    && pass "shellcheck clean" || fail "shellcheck errors"

# ── 3. metrics.sh produces well-formed metrics.txt from fixture data ──────────

begin_test "metrics.sh: produces metrics.txt from fixtures"
_out_dir=$(mktemp -d)
trap 'rm -rf "$_out_dir"' EXIT
# Create a minimal summary.txt so metrics.sh can append to it
printf 'Overall: PASS\n' > "$_out_dir/summary.txt"
printf '<!DOCTYPE html><html><body>test</body></html>\n' > "$_out_dir/summary.html"

# Run metrics.sh with fixture build/vm dirs and ccache-before file
BUILD_DIR="$FIX/build" RUN_STAMP="2026-09-27_10-00-00" \
    CONFIGS="defconfig tinyconfig" ARCHS="x86_64 arm64" \
    "$METRICS" "$_out_dir" "$FIX/ccache-stats-before.txt" 2>/dev/null \
    && pass "metrics.sh exited 0" \
    || fail "metrics.sh exited non-zero"

# ── 4. Required fields present in metrics.txt ────────────────────────────────

begin_test "metrics.txt: required fields present"
_mf="$_out_dir/metrics.txt"
if [[ ! -f $_mf ]]; then
    fail "metrics.txt not created"
else
    _missing=0
    for _field in RUN_STAMP BUILD_COMBOS BUILD_WALL_TIME \
                  CCACHE_HITS CCACHE_MISSES CCACHE_HIT_RATE_PCT \
                  TEST_COMBOS TEST_WALL_TIME; do
        grep -q "^${_field}=" "$_mf" || { fail "missing field: $_field"; _missing=1; }
    done
    [[ $_missing -eq 0 ]] && pass "all required fields present"
fi

# ── 5. Numeric fields are non-negative integers ───────────────────────────────

begin_test "metrics.txt: numeric fields are non-negative integers"
_bad=0
for _field in BUILD_COMBOS BUILD_WALL_TIME CCACHE_HITS CCACHE_MISSES \
              CCACHE_HIT_RATE_PCT TEST_COMBOS TEST_WALL_TIME; do
    _val=$(grep "^${_field}=" "$_mf" | cut -d= -f2)
    if ! printf '%s' "$_val" | grep -qE '^[0-9]+$'; then
        fail "field ${_field}=${_val} is not a non-negative integer"
        _bad=1
    fi
done
[[ $_bad -eq 0 ]] && pass "all numeric fields are valid integers"

# ── 6. BUILD_WALL_TIME ≥ max individual build time ───────────────────────────

begin_test "metrics.txt: BUILD_WALL_TIME >= max per-combo build time"
_wall=$(grep '^BUILD_WALL_TIME=' "$_mf" | cut -d= -f2)
_max_combo=0
while IFS= read -r _line; do
    _v=${_line#*=}
    [[ $_v -gt $_max_combo ]] && _max_combo=$_v
done < <(grep '^BUILD_TIME_' "$_mf")
if [[ $_wall -ge $_max_combo ]]; then
    pass "BUILD_WALL_TIME=${_wall}s >= max combo ${_max_combo}s"
else
    fail "BUILD_WALL_TIME=${_wall}s < max combo ${_max_combo}s — wall time impossible"
fi

# ── 7. monitor.sh --once runs and produces expected headers ──────────────────

begin_test "monitor.sh --once: produces expected output sections"
_mon_out=$(BUILD_DIR="$FIX/build" DATA_REPO="$FIX" \
    "$MONITOR" --once 2>/dev/null || true)
if printf '%s' "$_mon_out" | grep -q 'BUILDS'; then
    pass "BUILDS section present in monitor output"
else
    fail "BUILDS section missing from monitor --once output"
fi
if printf '%s' "$_mon_out" | grep -q 'TESTS'; then
    pass "TESTS section present in monitor output"
else
    fail "TESTS section missing from monitor --once output"
fi

# ── 8. build.sh: .build-active sentinel present ──────────────────────────────

begin_test "build.sh: .build-active sentinel touched on start"
grep -q '\.build-active' "$BUILD_SH" \
    && pass ".build-active referenced in build.sh" \
    || fail ".build-active not found in build.sh"

begin_test "build.sh: .build-active removed in EXIT trap"
grep -q 'rm -f.*\.build-active' "$BUILD_SH" \
    && pass ".build-active removed in trap" \
    || fail ".build-active not removed in EXIT trap"

# ── 9. vm.sh: .vm-active sentinel present ────────────────────────────────────

begin_test "vm.sh: .vm-active sentinel touched on start"
grep -q '\.vm-active' "$VM_SH" \
    && pass ".vm-active referenced in vm.sh" \
    || fail ".vm-active not found in vm.sh"

begin_test "vm.sh: .vm-active removed after vm.status written"
# vm-active must be removed after write_run_status (which writes vm.status).
# Check that rm -f .vm-active appears after write_run_status in the file.
_ws_line=$(grep -n 'write_run_status' "$VM_SH" | head -1 | cut -d: -f1)
_rm_line=$(grep -n 'rm -f.*\.vm-active' "$VM_SH" | head -1 | cut -d: -f1)
if [[ -n ${_ws_line:-} && -n ${_rm_line:-} && $_rm_line -gt $_ws_line ]]; then
    pass ".vm-active removed after write_run_status (line $_rm_line > $_ws_line)"
else
    fail ".vm-active not removed after write_run_status"
fi

# ── 10. Makefile: monitor target and ccache snapshot ─────────────────────────

begin_test "Makefile: monitor target present"
grep -q '^monitor:' "$MK" \
    && pass "monitor: target present" \
    || fail "monitor: target not found"

begin_test "Makefile: ccache-stats-before snapshot in build target"
if grep -A 5 '^build:' "$MK" | grep -q 'ccache-stats-before'; then
    pass "ccache-stats-before snapshot present in build target"
else
    fail "ccache-stats-before snapshot not found in build target"
fi

# ── 11. report.sh calls metrics.sh ───────────────────────────────────────────

begin_test "report.sh: calls lib/metrics.sh"
grep -q 'metrics\.sh' "$REPORT_SH" \
    && pass "metrics.sh called from report.sh" \
    || fail "metrics.sh not called from report.sh"

# ── 12. shellcheck: this test file ───────────────────────────────────────────

begin_test "shellcheck: test-metrics.sh"
shellcheck --severity=warning "$REPO/tests/ci/test-metrics.sh" \
    && pass "shellcheck clean" || fail "shellcheck errors"

finish
