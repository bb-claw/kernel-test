#!/bin/bash
# Tests for lib/report.sh — output format, OVERALL logic, auto-commit.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
setup_git_stub

make_build_dir() {
    local bdir="$1" cfg="$2" arch="$3" build_status="$4" boot="${5:-}"
    local out="$bdir/$cfg-$arch"
    mkdir -p "$out"
    local sha
    sha=$(printf 'CONFIG_FAKE=y\n' | sha256sum | cut -d' ' -f1)
    printf 'STATUS=%s\nSTART_TIME=2026-01-01T10:00:00Z\nDURATION=30\nCONFIG_SHA256=%s\nKERNEL_TREE=%s\n' \
        "$build_status" "$sha" "$KERNEL_TREE" > "$out/build.status"
    printf 'CONFIG_FAKE=y\n' > "$out/$cfg-$arch.config"
    if [[ -n "$boot" ]]; then
        printf 'BOOT=%s\nTESTS_PASS=5\nTESTS_FAIL=0\nTESTS_TOTAL=5\nKUNIT_PASS=0\nKUNIT_FAIL=0\nSTART_TIME=2026-01-01T10:00:30Z\nDURATION=10\n' \
            "$boot" > "$out/vm.status"
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

finish
