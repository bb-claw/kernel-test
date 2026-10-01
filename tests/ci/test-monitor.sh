#!/bin/bash
# CI tests for lib/monitor.sh --once snapshot mode.
# Covers coverage-map paths: M1 (exits 0 with no active run), M2 (BUILDS/TESTS headers).
# Does not require a running kernel build, QEMU, or ccache.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── M1: --once exits 0 with no active run ────────────────────────────────────

begin_test "monitor-once-exits-0"
tmpdir
_bd="$_LAST_TMPDIR/build-absent"
_rd="$_LAST_TMPDIR/reports"
mkdir -p "$_rd"
assert_exit0 "M1: --once exits 0 with absent build dir" \
    env BUILD_DIR="$_bd" REPORT_DIR="$_rd" bash "$REPO/lib/monitor.sh" --once

# ── M2: output contains BUILDS and TESTS section headers ─────────────────────

begin_test "monitor-once-section-headers"
tmpdir
_bd="$_LAST_TMPDIR/build"
_rd="$_LAST_TMPDIR/reports"
mkdir -p "$_bd" "$_rd"
_mon_out=$(BUILD_DIR="$_bd" REPORT_DIR="$_rd" bash "$REPO/lib/monitor.sh" --once 2>&1) || true
assert_contains "$_mon_out" "BUILDS" "M2: BUILDS header present"
assert_contains "$_mon_out" "TESTS"  "M2: TESTS header present"

# ── Helpers for scoping tests ─────────────────────────────────────────────────

# Write a minimal .run-plan into $1.
# Args: dir configs archs [boot_configs]
write_run_plan() {
    local dir="$1" configs="$2" archs="$3" boot="${4:-$2}"
    printf 'BUILD_TOTAL=1\nTEST_TOTAL=1\nCONFIGS=%s\nARCHS=%s\nBOOT_CONFIGS=%s\n' \
        "$configs" "$archs" "$boot" > "$dir/.run-plan"
}

# Run monitor --once; always exits 0; returns output.
mon_once() {
    local bd="$1" rd="$2"
    BUILD_DIR="$bd" REPORT_DIR="$rd" bash "$REPO/lib/monitor.sh" --once 2>&1 || true
}

# ── M3: out-of-plan build sentinel filtered by combo membership ───────────────
# .build-active exists for allmodconfig-x86_64 (newer than .run-plan) but
# CONFIGS=tinyconfig; the combo filter must exclude it from the active list.

begin_test "monitor-out-of-plan-build-sentinel-filtered"
tmpdir; _bd="$_LAST_TMPDIR/build"; _rd="$_LAST_TMPDIR/reports"
mkdir -p "$_bd/allmodconfig-x86_64" "$_rd"
# Write .run-plan first (older mtime), then the sentinel (newer)
write_run_plan "$_bd" "tinyconfig" "x86_64"
touch -t 202001010000 "$_bd/.run-plan"
printf '4\n' > "$_bd/allmodconfig-x86_64/.build-active"
_out=$(mon_once "$_bd" "$_rd")
assert_not_contains "$_out" "allmodconfig-x86_64" "M3: out-of-plan combo absent from active builds"
assert_contains     "$_out" "(0 active"            "M3: active count shows 0 (not inflated by out-of-plan sentinel)"

# ── M4: stale same-combo build sentinel filtered by mtime ─────────────────────
# .build-active for tinyconfig-x86_64 is older than .run-plan; -newer guard must
# exclude it even though the combo is in the plan.

begin_test "monitor-stale-build-sentinel-filtered-by-mtime"
tmpdir; _bd="$_LAST_TMPDIR/build"; _rd="$_LAST_TMPDIR/reports"
mkdir -p "$_bd/tinyconfig-x86_64" "$_rd"
# Create sentinel with an old mtime, then .run-plan with current time
printf '4\n' > "$_bd/tinyconfig-x86_64/.build-active"
touch -t 202001010000 "$_bd/tinyconfig-x86_64/.build-active"
write_run_plan "$_bd" "tinyconfig" "x86_64"
_out=$(mon_once "$_bd" "$_rd")
assert_not_contains "$_out" "tinyconfig-x86_64" "M4: stale same-combo sentinel not shown as active"
assert_contains     "$_out" "(0 active"          "M4: active count is 0 for stale sentinel"

# ── M5: valid current-run build sentinel shown as active ──────────────────────
# .build-active for tinyconfig-x86_64 is newer than .run-plan and the combo is
# in the plan; it must appear in the active build list.

begin_test "monitor-valid-build-sentinel-shown-as-active"
tmpdir; _bd="$_LAST_TMPDIR/build"; _rd="$_LAST_TMPDIR/reports"
mkdir -p "$_bd/tinyconfig-x86_64" "$_rd"
# Write .run-plan with old mtime so the sentinel (written now) is definitely newer
write_run_plan "$_bd" "tinyconfig" "x86_64"
touch -t 202001010000 "$_bd/.run-plan"
printf '4\n' > "$_bd/tinyconfig-x86_64/.build-active"
_out=$(mon_once "$_bd" "$_rd")
assert_contains     "$_out" "tinyconfig-x86_64" "M5: valid in-plan sentinel shown as active build"
assert_contains     "$_out" "(1 active"          "M5: active count is 1 for valid sentinel"

# ── M6: out-of-plan test sentinel filtered by combo membership ────────────────
# .vm-active exists for allmodconfig-x86_64 (newer than .run-plan) but
# BOOT_CONFIGS=tinyconfig; the combo filter must exclude it.

begin_test "monitor-out-of-plan-test-sentinel-filtered"
tmpdir; _bd="$_LAST_TMPDIR/build"; _rd="$_LAST_TMPDIR/reports"
mkdir -p "$_bd/allmodconfig-x86_64" "$_rd"
write_run_plan "$_bd" "tinyconfig" "x86_64" "tinyconfig"
touch -t 202001010000 "$_bd/.run-plan"
touch "$_bd/allmodconfig-x86_64/.vm-active"
_out=$(mon_once "$_bd" "$_rd")
assert_not_contains "$_out" "allmodconfig-x86_64" "M6: out-of-plan vm-active absent from active tests"

# ── M7: stale same-combo test sentinel filtered by mtime ──────────────────────
# .vm-active for tinyconfig-x86_64 is older than .run-plan; -newer guard must
# exclude it.

begin_test "monitor-stale-test-sentinel-filtered-by-mtime"
tmpdir; _bd="$_LAST_TMPDIR/build"; _rd="$_LAST_TMPDIR/reports"
mkdir -p "$_bd/tinyconfig-x86_64" "$_rd"
touch "$_bd/tinyconfig-x86_64/.vm-active"
touch -t 202001010000 "$_bd/tinyconfig-x86_64/.vm-active"
write_run_plan "$_bd" "tinyconfig" "x86_64" "tinyconfig"
_out=$(mon_once "$_bd" "$_rd")
assert_not_contains "$_out" "tinyconfig-x86_64" "M7: stale vm-active not shown in active tests"

# ── M8: valid current-run test sentinel shown in active tests ─────────────────
# .vm-active for tinyconfig-x86_64 is newer than .run-plan and the combo is
# in BOOT_CONFIGS; it must appear in the active test list.

begin_test "monitor-valid-test-sentinel-shown-as-active"
tmpdir; _bd="$_LAST_TMPDIR/build"; _rd="$_LAST_TMPDIR/reports"
mkdir -p "$_bd/tinyconfig-x86_64" "$_rd"
write_run_plan "$_bd" "tinyconfig" "x86_64" "tinyconfig"
touch -t 202001010000 "$_bd/.run-plan"
touch "$_bd/tinyconfig-x86_64/.vm-active"
_out=$(mon_once "$_bd" "$_rd")
assert_contains "$_out" "tinyconfig-x86_64" "M8: valid in-plan vm-active shown in active tests"

finish
