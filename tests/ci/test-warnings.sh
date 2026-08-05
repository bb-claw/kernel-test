#!/bin/bash
# Tests for lib/warnings.sh — warning extraction, prefix stripping, FAIL-skip,
# cross-arch divergence detection, and between-run diff.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

run_warnings() {
    local run_dir="$1" bdir="$2" configs="$3" archs="$4"
    BUILD_DIR="$bdir" \
    CONFIGS="$configs" \
    ARCHS="$archs" \
    REPORT_DIR="$(dirname "$run_dir")" \
    "$REPO/lib/warnings.sh" "$run_dir" 2>&1 || true
}

# Create a build dir with a given STATUS and optional warning lines in build.log.
make_build() {
    local bdir="$1" cfg="$2" arch="$3" status="$4"
    local out="$bdir/$cfg-$arch"
    mkdir -p "$out"
    printf 'STATUS=%s\n' "$status" > "$out/build.status"
    touch "$out/build.log"
}

# Append a ': warning:' line to a build log (with the build dir prefix).
add_warning() {
    local bdir="$1" cfg="$2" arch="$3" msg="$4"
    local out="$bdir/$cfg-$arch"
    printf '%s/drivers/foo.c: warning: %s\n' "$out" "$msg" >> "$out/build.log"
}

make_run_dir() {
    local report_dir="$1" label="${2:-mainline}" ver="${3:-v7.2-rc99}"
    local rd="$report_dir/${label}-7.2-2026-01-01_10-00-00-${ver}"
    mkdir -p "$rd"
    printf '%s' "$rd"
}

# ── basic warning extraction ───────────────────────────────────────────────────

begin_test "warning lines extracted from build log"
tmpdir; bdir="$_LAST_TMPDIR"
tmpdir; report_dir="$_LAST_TMPDIR"
run_dir=$(make_run_dir "$report_dir")
make_build "$bdir" tinyconfig x86_64 PASS
add_warning "$bdir" tinyconfig x86_64 "implicit declaration of function"
printf 'CC drivers/foo.c\n' >> "$bdir/tinyconfig-x86_64/build.log"
run_warnings "$run_dir" "$bdir" tinyconfig x86_64
assert_file_exists "$run_dir/warnings-tinyconfig-x86_64.txt" "per-combo file written"
content=$(cat "$run_dir/warnings-tinyconfig-x86_64.txt")
assert_contains     "$content" "implicit declaration"  "warning extracted"
assert_not_contains "$content" "CC drivers"            "non-warning line excluded"

# ── build dir prefix stripped ─────────────────────────────────────────────────

begin_test "absolute build dir prefix stripped from warning paths"
tmpdir; bdir="$_LAST_TMPDIR"
tmpdir; report_dir="$_LAST_TMPDIR"
run_dir=$(make_run_dir "$report_dir")
make_build "$bdir" tinyconfig x86_64 PASS
add_warning "$bdir" tinyconfig x86_64 "some warning"
run_warnings "$run_dir" "$bdir" tinyconfig x86_64
content=$(cat "$run_dir/warnings-tinyconfig-x86_64.txt")
assert_not_contains "$content" "$bdir" "absolute build path removed"
assert_contains     "$content" "drivers/foo.c" "relative path retained"

# ── FAIL build skipped ────────────────────────────────────────────────────────

begin_test "FAIL builds produce no per-combo warning file"
tmpdir; bdir="$_LAST_TMPDIR"
tmpdir; report_dir="$_LAST_TMPDIR"
run_dir=$(make_run_dir "$report_dir")
make_build "$bdir" tinyconfig x86_64 FAIL
add_warning "$bdir" tinyconfig x86_64 "should not appear"
run_warnings "$run_dir" "$bdir" tinyconfig x86_64
if [[ ! -f "$run_dir/warnings-tinyconfig-x86_64.txt" ]]; then
    pass "no warning file for FAIL build"
else
    fail "warning file unexpectedly written for FAIL build"
fi

# ── warnings-summary.txt always written ──────────────────────────────────────

begin_test "warnings-summary.txt written with counts table"
tmpdir; bdir="$_LAST_TMPDIR"
tmpdir; report_dir="$_LAST_TMPDIR"
run_dir=$(make_run_dir "$report_dir")
make_build "$bdir" tinyconfig x86_64 PASS
add_warning "$bdir" tinyconfig x86_64 "a warning"
run_warnings "$run_dir" "$bdir" tinyconfig x86_64
assert_file_exists "$run_dir/warnings-summary.txt" "summary file written"
summary=$(cat "$run_dir/warnings-summary.txt")
assert_contains "$summary" "Warning Summary"      "summary header present"
assert_contains "$summary" "tinyconfig-x86_64"   "combo in counts table"
assert_contains "$summary" "CROSS-ARCH DIVERGENCE" "divergence section present"

# ── cross-arch divergence ─────────────────────────────────────────────────────

begin_test "cross-arch divergence detected when non-x86_64 has extra warnings"
tmpdir; bdir="$_LAST_TMPDIR"
tmpdir; report_dir="$_LAST_TMPDIR"
run_dir=$(make_run_dir "$report_dir")
make_build "$bdir" tinyconfig x86_64 PASS
make_build "$bdir" tinyconfig arm64  PASS
add_warning "$bdir" tinyconfig arm64 "arm-specific issue"
run_warnings "$run_dir" "$bdir" tinyconfig "x86_64 arm64"
summary=$(cat "$run_dir/warnings-summary.txt")
assert_contains "$summary" "arm-specific issue" "divergent arm64 warning listed"

# ── between-run diff ──────────────────────────────────────────────────────────

begin_test "between-run diff identifies new warnings"
tmpdir; bdir="$_LAST_TMPDIR"
tmpdir; report_dir="$_LAST_TMPDIR"
# Old run: empty warning file (previous run already extracted)
old_run="$report_dir/mainline-7.2-2026-01-01_09-00-00-v7.2-rc98"
mkdir -p "$old_run"
printf '' > "$old_run/warnings-tinyconfig-x86_64.txt"
# New run: build log has a new warning
new_run=$(make_run_dir "$report_dir" mainline v7.2-rc99)
make_build "$bdir" tinyconfig x86_64 PASS
add_warning "$bdir" tinyconfig x86_64 "newly introduced warning"
run_warnings "$new_run" "$bdir" tinyconfig x86_64
assert_file_exists "$new_run/warnings-diff-prev.txt" "diff-prev.txt written"
diff_txt=$(cat "$new_run/warnings-diff-prev.txt")
assert_contains "$diff_txt" "NEW WARNINGS"             "new warnings section present"
assert_contains "$diff_txt" "newly introduced warning" "specific warning listed in diff"

finish
