#!/bin/bash
# Tests for make extended combined summary:
#   - First report.sh pass writes sentinel in BUILD_DIR
#   - Second pass with same RUN_STAMP merges first-pass configs into combined summary
#   - Stale sentinel (different RUN_STAMP) is discarded; standalone behaviour preserved
#   - OVERALL reflects all combined configs
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
setup_git_stub

# ── Helpers ───────────────────────────────────────────────────────────────────

make_build_dir() {
    local bdir="$1" cfg="$2" arch="$3" build_st="${4:-PASS}" boot="${5:-PASS}"
    local out="$bdir/$cfg-$arch"
    mkdir -p "$out"
    local sha
    sha=$(printf 'CONFIG_FAKE=y\n' | sha256sum | cut -d' ' -f1)
    printf 'STATUS=%s\nSTART_TIME=2026-01-01T10:00:00Z\nDURATION=30\nCONFIG_SHA256=%s\nKERNEL_TREE=%s\n' \
        "$build_st" "$sha" "$KERNEL_TREE" > "$out/build.status"
    printf 'CONFIG_FAKE=y\n' > "$out/.config"
    if [[ "$build_st" == "PASS" ]]; then
        printf 'BOOT=%s\nTESTS_PASS=5\nTESTS_FAIL=0\nTESTS_TOTAL=5\nKUNIT_PASS=0\nKUNIT_FAIL=0\nSTART_TIME=2026-01-01T10:00:30Z\nDURATION=10\n' \
            "$boot" > "$out/vm.status"
    fi
    touch "$out/build.log"
}

# run_report BDIR CONFIGS ARCHS [RUN_STAMP]
run_report() {
    local bdir="$1" configs="$2" archs="$3" stamp="${4:-2026-01-01T10:00:00Z}"
    BUILD_DIR="$bdir" \
    DATA_REPO="$DATA_REPO" \
    REPORT_DIR="$REPORT_DIR" \
    KERNEL_TREE="$KERNEL_TREE" \
    CONFIGS="$configs" \
    ARCHS="$archs" \
    BUILD_ONLY_CONFIGS="allmodconfig randconfig" \
    RUN_STAMP="$stamp" \
    LABEL="mainline" \
    GCC="gcc" \
    TOYBOX_VERSION="0.8.14" \
    TIMEOUT="360" \
    "$REPO/lib/report.sh" 2>&1 || true
}

# ── Sentinel: written after first pass ───────────────────────────────────────

begin_test "sentinel written after first pass"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64
run_report "$bdir" "tinyconfig" "x86_64"
assert_file_exists "$bdir/.report-extended-phase" "sentinel file exists"

begin_test "sentinel contains correct RUN_STAMP"
txt=$(cat "$bdir/.report-extended-phase")
assert_contains "$txt" "RUN_STAMP=2026-01-01T10:00:00Z" "RUN_STAMP in sentinel"

begin_test "sentinel contains first-pass CONFIGS"
assert_contains "$txt" "CONFIGS=tinyconfig" "CONFIGS in sentinel"

# ── Extended two-pass: combined summary ───────────────────────────────────────

begin_test "extended two-pass: combined summary contains phase-1 config"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64
make_build_dir "$bdir" defconfig x86_64
run_report "$bdir" "tinyconfig" "x86_64"
run_report "$bdir" "defconfig"  "x86_64"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "tinyconfig" "tinyconfig row in combined summary"

begin_test "extended two-pass: combined summary contains phase-2 config"
assert_contains "$txt" "defconfig" "defconfig row in combined summary"

begin_test "extended two-pass: sentinel deleted after second pass"
assert_ne "$(ls "$bdir/.report-extended-phase" 2>/dev/null || echo MISSING)" \
    "$bdir/.report-extended-phase" "sentinel removed after second pass"

begin_test "extended two-pass: OVERALL=PASS when all configs pass"
assert_not_contains "$txt" "Result:     FAIL" "OVERALL=PASS in combined summary"

# ── Extended two-pass: OVERALL propagates phase-1 failure ────────────────────

begin_test "extended two-pass: OVERALL=FAIL when phase-1 config fails"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 FAIL
make_build_dir "$bdir" defconfig  x86_64 PASS
run_report "$bdir" "tinyconfig" "x86_64"
run_report "$bdir" "defconfig"  "x86_64"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Result:     FAIL" "OVERALL=FAIL when phase-1 failed"

begin_test "extended two-pass: OVERALL=FAIL when phase-2 config fails"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS
make_build_dir "$bdir" defconfig  x86_64 FAIL
run_report "$bdir" "tinyconfig" "x86_64"
run_report "$bdir" "defconfig"  "x86_64"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Result:     FAIL" "OVERALL=FAIL when phase-2 failed"

# ── Stale sentinel: different RUN_STAMP → standalone behaviour ────────────────

begin_test "stale sentinel discarded: summary has only current-pass config"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64
make_build_dir "$bdir" defconfig  x86_64
# Write a sentinel with a different RUN_STAMP (stale)
printf 'RUN_STAMP=2025-12-31T00:00:00Z\nCONFIGS=tinyconfig\n' \
    > "$bdir/.report-extended-phase"
run_report "$bdir" "defconfig" "x86_64" "2026-01-01T10:00:00Z"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains     "$txt" "defconfig"  "defconfig in standalone summary"
assert_not_contains "$txt" "tinyconfig" "tinyconfig not in summary (stale sentinel discarded)"

begin_test "stale sentinel replaced: old stamp gone from sentinel"
new_sentinel=$(cat "$bdir/.report-extended-phase" 2>/dev/null || echo "")
assert_not_contains "$new_sentinel" "2025-12-31T00:00:00Z" "stale RUN_STAMP replaced in sentinel"

# ── Standalone make full: sentinel written but standalone summary correct ──────

begin_test "standalone run: summary has only its own config (no phantom rows)"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64
make_build_dir "$bdir" defconfig  x86_64
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains     "$txt" "tinyconfig" "tinyconfig in summary"
assert_not_contains "$txt" "defconfig"  "defconfig absent in standalone summary"

# ── Row ordering: phase-1 rows appear before phase-2 rows ────────────────────

begin_test "extended two-pass: phase-1 rows appear before phase-2 rows"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64
make_build_dir "$bdir" defconfig  x86_64
run_report "$bdir" "tinyconfig" "x86_64"
run_report "$bdir" "defconfig"  "x86_64"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -1)
# tinyconfig row must appear before defconfig row in the table
tiny_line=$(grep -n 'tinyconfig' "$run_dir/summary.txt" | head -1 | cut -d: -f1)
def_line=$(grep -n 'defconfig'  "$run_dir/summary.txt" | head -1 | cut -d: -f1)
assert_ne "$tiny_line" "" "tinyconfig line found"
assert_ne "$def_line"  "" "defconfig line found"
if [[ -n $tiny_line && -n $def_line && $tiny_line -lt $def_line ]]; then
    pass "tinyconfig row before defconfig row"
else
    fail "tinyconfig row before defconfig row: tinyconfig=$tiny_line defconfig=$def_line"
fi

finish
