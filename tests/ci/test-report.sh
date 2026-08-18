#!/bin/bash
# Tests for lib/report.sh — output format, OVERALL logic, auto-commit.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
setup_git_stub

make_build_dir() {
    local bdir="$1" cfg="$2" arch="$3" build_status="$4" boot="${5:-}" \
          kunit_pass="${6:-0}" kunit_fail="${7:-0}" tests_fail="${8:-0}" tests_pass="${9:-5}"
    local out="$bdir/$cfg-$arch"
    mkdir -p "$out"
    local sha
    sha=$(printf 'CONFIG_FAKE=y\n' | sha256sum | cut -d' ' -f1)
    printf 'STATUS=%s\nSTART_TIME=2026-01-01T10:00:00Z\nDURATION=30\nCONFIG_SHA256=%s\nKERNEL_TREE=%s\n' \
        "$build_status" "$sha" "$KERNEL_TREE" > "$out/build.status"
    printf 'CONFIG_FAKE=y\n' > "$out/.config"
    if [[ -n "$boot" ]]; then
        local tests_total
        tests_total=$(( tests_pass + tests_fail ))
        printf 'BOOT=%s\nTESTS_PASS=%s\nTESTS_FAIL=%s\nTESTS_TOTAL=%s\nKUNIT_PASS=%s\nKUNIT_FAIL=%s\nSTART_TIME=2026-01-01T10:00:30Z\nDURATION=10\n' \
            "$boot" "$tests_pass" "$tests_fail" "$tests_total" "$kunit_pass" "$kunit_fail" \
            > "$out/vm.status"
    fi
    touch "$out/build.log"
}

run_report() {
    local bdir="$1" configs="$2" archs="$3"
    BUILD_DIR="$bdir" \
    DATA_REPO="$DATA_REPO" \
    REPORT_DIR="$REPORT_DIR" \
    KERNEL_TREE="$KERNEL_TREE" \
    CONFIGS="$configs" \
    ARCHS="$archs" \
    BUILD_ONLY_CONFIGS="allmodconfig randconfig" \
    RUN_STAMP="2026-01-01T10:00:00Z" \
    LABEL="mainline" \
    GCC="gcc" \
    TOYBOX_VERSION="0.8.14" \
    TIMEOUT="360" \
    "$REPO/lib/report.sh" 2>&1 || true
}

# ── OVERALL=PASS when all pass ────────────────────────────────────────────────

begin_test "OVERALL=PASS when build+boot pass"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS PASS
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
assert_ne "$run_dir" "" "report dir created"
txt=$(cat "$run_dir/summary.txt")
assert_not_contains "$txt" "Result:     FAIL" "not a FAIL result"

# ── OVERALL=FAIL when build fails ────────────────────────────────────────────

begin_test "OVERALL=FAIL when build fails"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 FAIL
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Result:     FAIL" "FAIL result when build fails"

# ── OVERALL=FAIL when boot fails ─────────────────────────────────────────────

begin_test "OVERALL=FAIL when boot fails"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS FAIL
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Result:     FAIL" "FAIL result when boot fails"

# ── summary.txt structure ─────────────────────────────────────────────────────

begin_test "summary.txt has required sections"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS PASS
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Subject:"    "subject line present"
assert_contains "$txt" "Tested-by:"  "tested-by line present"
assert_contains "$txt" "tinyconfig"  "config in results table"
assert_contains "$txt" "x86_64"      "arch in results table"
assert_file_exists "$run_dir/summary.html"     "summary.html written"
assert_file_exists "$run_dir/summary.mail.txt" "summary.mail.txt written"

# ── report dir auto-committed to DATA_REPO ───────────────────────────────────

begin_test "report dir committed to DATA_REPO git"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS PASS
run_report "$bdir" "tinyconfig" "x86_64"
log=$(git -C "$DATA_REPO" log --oneline | head -3)
assert_contains "$log" "chore(report)" "auto-commit present in data repo"

# ── OVERALL=FAIL when kunit tests fail ───────────────────────────────────────

begin_test "OVERALL=FAIL when kunit tests fail"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" kunitconfig x86_64 PASS PASS 257 2
run_report "$bdir" "kunitconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Result:     FAIL" "FAIL when kunit_fail > 0"

# ── OVERALL=FAIL when shell tests fail ───────────────────────────────────────

begin_test "OVERALL=FAIL when shell tests fail"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS PASS 0 0 1 4
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Result:     FAIL" "FAIL when tests_fail > 0"

# ── OVERALL=FAIL on config fingerprint mismatch ──────────────────────────────

begin_test "OVERALL=FAIL when config fingerprint mismatches"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS PASS
# Overwrite SHA256 in build.status with a wrong value
printf 'STATUS=PASS\nSTART_TIME=2026-01-01T10:00:00Z\nDURATION=30\nCONFIG_SHA256=%s\nKERNEL_TREE=%s\n' \
    "0000000000000000000000000000000000000000000000000000000000000000" "$KERNEL_TREE" \
    > "$bdir/tinyconfig-x86_64/build.status"
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Result:     FAIL" "FAIL on fingerprint mismatch"
assert_contains "$txt" "MISMATCH"         "MISMATCH visible in fingerprint table"

# ── build-only config shows — in Tests column ────────────────────────────────

begin_test "build-only config shows — in Tests column"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" allmodconfig x86_64 TIMEOUT
run_report "$bdir" "allmodconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains     "$txt" "build-only" "boot column shows build-only"
assert_not_contains "$txt" "5/5"        "no test count for build-only"

# ── kunit count format in Tests column ───────────────────────────────────────

begin_test "kunit count format: kunit:N/N sh:M/M in Tests column"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" kunitconfig x86_64 PASS PASS 259 0 0 30
run_report "$bdir" "kunitconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "kunit:259/259" "kunit count format correct"
assert_contains "$txt" "sh:30/30"      "shell test count alongside kunit"

# ── Stale-variable regression: failed count must not bleed between rows ───────

begin_test "Notes: failed count per-row, no bleed into passing row (stale-variable regression)"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
# Row 1 (tinyconfig): 1 failed test with FAILED_TESTS set
make_build_dir "$bdir" tinyconfig x86_64 PASS PASS 0 0 1 4
printf 'FAILED_TESTS=480_snapshot\n' >> "$bdir/tinyconfig-x86_64/vm.status"
# Row 2 (defconfig): all pass, no FAILED_TESTS
make_build_dir "$bdir" defconfig x86_64 PASS PASS 0 0 0 5
run_report "$bdir" "tinyconfig defconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
tinyconfig_line=$(grep '^tinyconfig' "$run_dir/summary.txt" | head -1 || true)
defconfig_line=$(grep '^defconfig'  "$run_dir/summary.txt" | head -1 || true)
assert_contains     "$tinyconfig_line" "1 failed" "tinyconfig row shows 1 failed"
assert_not_contains "$defconfig_line"  "failed"   "defconfig row: no stale failed count"

# ── Stale-variable regression: no bleed into build-only row ───────────────────

begin_test "Notes: failed count does not bleed into build-only row"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
# Row 1 (tinyconfig): 1 failed test
make_build_dir "$bdir" tinyconfig x86_64 PASS PASS 0 0 1 4
printf 'FAILED_TESTS=480_snapshot\n' >> "$bdir/tinyconfig-x86_64/vm.status"
# Row 2 (allmodconfig): build-only, no vm.status
make_build_dir "$bdir" allmodconfig x86_64 PASS
run_report "$bdir" "tinyconfig allmodconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
allmodconfig_line=$(grep '^allmodconfig' "$run_dir/summary.txt" | head -1 || true)
assert_not_contains "$allmodconfig_line" "failed" "allmodconfig row: no bleed from prior failing row"

# ── fail_reason visible in Notes column ───────────────────────────────────────

begin_test "Notes: fail_reason shown when boot fails"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS FAIL
printf 'FAIL_REASON=timeout\n' >> "$bdir/tinyconfig-x86_64/vm.status"
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
tinyconfig_line=$(grep '^tinyconfig' "$run_dir/summary.txt" | head -1 || true)
assert_contains "$tinyconfig_line" "timeout" "fail_reason appears in Notes"

# ── cfg-fixed flag in Notes column ───────────────────────────────────────────

begin_test "Notes: cfg-fixed shown when CONFIG_CORRECTED=1"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS PASS
printf 'CONFIG_CORRECTED=1\n' >> "$bdir/tinyconfig-x86_64/build.status"
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
tinyconfig_line=$(grep '^tinyconfig' "$run_dir/summary.txt" | head -1 || true)
assert_contains "$tinyconfig_line" "cfg-fixed" "cfg-fixed appears in Notes when CONFIG_CORRECTED=1"

# ── HTML Notes: failed test names listed ─────────────────────────────────────

begin_test "HTML Notes: failed test names listed in span"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64 PASS PASS 0 0 1 4
printf 'FAILED_TESTS=480_snapshot\n' >> "$bdir/tinyconfig-x86_64/vm.status"
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$DATA_REPO/reports" -maxdepth 1 -mindepth 1 -type d | head -1)
html=$(cat "$run_dir/summary.html")
assert_contains "$html" "failed: 480_snapshot" "HTML Notes lists failed test name"
assert_contains "$html" "class=\"fail\""        "HTML Notes uses fail CSS class"

finish
