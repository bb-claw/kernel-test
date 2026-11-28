#!/bin/bash
# Tests for:
#   Bug 1 — make extended recipe continues past sub-make failures (rc accumulator)
#   Bug 2 — perf-build writes build.status; report.sh includes Perf build: line
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
setup_git_stub

# ── Helper: run report.sh with a pre-built build dir ─────────────────────────

run_report() {
    local bdir="$1" configs="${2:-tinyconfig}" archs="${3:-x86_64}"
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

make_build_dir() {
    local bdir="$1" cfg="$2" arch="$3"
    local out="$bdir/$cfg-$arch"
    mkdir -p "$out"
    local sha
    sha=$(printf 'CONFIG_FAKE=y\n' | sha256sum | cut -d' ' -f1)
    printf 'STATUS=PASS\nSTART_TIME=2026-01-01T10:00:00Z\nDURATION=30\nCONFIG_SHA256=%s\nKERNEL_TREE=%s\n' \
        "$sha" "$KERNEL_TREE" > "$out/build.status"
    printf 'CONFIG_FAKE=y\n' > "$out/.config"
    printf 'BOOT=PASS\nTESTS_PASS=5\nTESTS_FAIL=0\nTESTS_TOTAL=5\nKUNIT_PASS=0\nKUNIT_FAIL=0\nSTART_TIME=2026-01-01T10:00:30Z\nDURATION=10\n' \
        > "$out/vm.status"
    touch "$out/build.log"
}

# ── Bug 1: extended recipe structure ─────────────────────────────────────────

begin_test "extended recipe contains rc accumulator for full"
recipe=$(grep -A6 '^extended:' "$REPO/Makefile")
assert_contains "$recipe" '$(MAKE) full' "calls full"
assert_contains "$recipe" '|| rc=' "full has || rc= guard"

begin_test "extended recipe contains rc accumulator for ns-full"
recipe=$(grep -A6 '^extended:' "$REPO/Makefile")
assert_contains "$recipe" '$(MAKE) ns-full' "calls ns-full"
assert_contains "$recipe" '$(MAKE) perf-build' "calls perf-build"

begin_test "extended recipe exits with accumulated rc"
recipe=$(grep -A6 '^extended:' "$REPO/Makefile")
assert_contains "$recipe" 'exit $$rc' "exits with accumulated rc"

begin_test "extended recipe does not use bare sub-make without guard"
assert_not_contains "$recipe" '+@$(MAKE) full' "full is guarded, not bare"

# ── Bug 1: functional — all phases run when full fails ────────────────────────

begin_test "extended: ns-full and perf-build run when full fails"
tmpdir; td="$_LAST_TMPDIR"
cat > "$td/Makefile" <<MAKEFILE
extended:
	+@rc=0; \\
	 \$(MAKE) full       || rc=\$\$?; \\
	 \$(MAKE) ns-full    || rc=\$\$?; \\
	 \$(MAKE) perf-build || rc=\$\$?; \\
	 exit \$\$rc
full:
	@exit 1
ns-full:
	@touch $td/ns-full-ran
perf-build:
	@touch $td/perf-build-ran
MAKEFILE
make -C "$td" extended >/dev/null 2>&1 || true
assert_file_exists "$td/ns-full-ran"    "ns-full ran after full failure"
assert_file_exists "$td/perf-build-ran" "perf-build ran after full failure"

begin_test "extended exits non-zero when any phase fails"
tmpdir; td="$_LAST_TMPDIR"
cat > "$td/Makefile" <<'MAKEFILE'
extended:
	+@rc=0; \
	 $(MAKE) fail-phase  || rc=$$?; \
	 $(MAKE) pass-phase  || rc=$$?; \
	 exit $$rc
fail-phase:
	@exit 1
pass-phase:
	@echo "pass-phase-ran"
MAKEFILE
rc=0; make -C "$td" extended >/dev/null 2>&1 || rc=$?
assert_ne "$rc" "0" "extended exits non-zero when a phase fails"

begin_test "extended exits zero when all phases pass"
tmpdir; td="$_LAST_TMPDIR"
cat > "$td/Makefile" <<'MAKEFILE'
extended:
	+@rc=0; \
	 $(MAKE) pass-a || rc=$$?; \
	 $(MAKE) pass-b || rc=$$?; \
	 exit $$rc
pass-a:
	@echo "a"
pass-b:
	@echo "b"
MAKEFILE
assert_exit0 "extended exits zero when all pass" make -C "$td" extended

begin_test "extended: full and ns-full run when perf-build fails"
tmpdir; td="$_LAST_TMPDIR"
cat > "$td/Makefile" <<MAKEFILE
extended:
	+@rc=0; \\
	 \$(MAKE) full       || rc=\$\$?; \\
	 \$(MAKE) ns-full    || rc=\$\$?; \\
	 \$(MAKE) perf-build || rc=\$\$?; \\
	 exit \$\$rc
full:
	@touch $td/full-ran
ns-full:
	@touch $td/ns-full-ran
perf-build:
	@exit 1
MAKEFILE
rc=0; make -C "$td" extended >/dev/null 2>&1 || rc=$?
assert_file_exists "$td/full-ran"       "full ran"
assert_file_exists "$td/ns-full-ran"    "ns-full ran"
assert_ne "$rc" "0" "extended exits non-zero when perf-build fails"

# ── Bug 2: perf-build writes build.status ────────────────────────────────────

begin_test "perf-build NO_PERF_BUILD=1 writes STATUS=SKIP"
tmpdir; bd="$_LAST_TMPDIR"
make -C "$REPO" perf-build NO_PERF_BUILD=1 BUILD_DIR="$bd" >/dev/null 2>&1
assert_file_exists "$bd/perf/build.status" "build.status created on skip"
status=$(grep '^STATUS=' "$bd/perf/build.status" | cut -d= -f2)
assert_eq "$status" "SKIP" "STATUS=SKIP written"

begin_test "perf-build status file has correct format"
tmpdir; bd="$_LAST_TMPDIR"
make -C "$REPO" perf-build NO_PERF_BUILD=1 BUILD_DIR="$bd" >/dev/null 2>&1
assert_contains "$(cat "$bd/perf/build.status")" "STATUS=" "STATUS= line present"

begin_test "perf-build FAIL path writes STATUS=FAIL"
tmpdir; bd="$_LAST_TMPDIR"
tmpdir; kt="$_LAST_TMPDIR"
# kt has no tools/perf — inner make fails cleanly
make -C "$REPO" perf-build BUILD_DIR="$bd" KERNEL_TREE="$kt" >/dev/null 2>&1 || true
assert_file_exists "$bd/perf/build.status" "build.status created on failure"
status=$(grep '^STATUS=' "$bd/perf/build.status" | cut -d= -f2)
assert_eq "$status" "FAIL" "STATUS=FAIL written on build failure"

# ── Bug 2: report.sh includes Perf build line ────────────────────────────────

begin_test "report.sh shows 'Perf build: PASS' when status is PASS"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64
mkdir -p "$bdir/perf"
printf 'STATUS=PASS\n' > "$bdir/perf/build.status"
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Perf build: PASS" "PASS status in summary"

begin_test "report.sh shows 'Perf build: FAIL' when status is FAIL"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64
mkdir -p "$bdir/perf"
printf 'STATUS=FAIL\n' > "$bdir/perf/build.status"
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Perf build: FAIL" "FAIL status in summary"

begin_test "report.sh shows 'Perf build: skipped' when status is SKIP"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64
mkdir -p "$bdir/perf"
printf 'STATUS=SKIP\n' > "$bdir/perf/build.status"
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_contains "$txt" "Perf build: skipped" "SKIP status in summary"

begin_test "report.sh has no Perf build line when status file absent"
setup_kernel_tree; setup_data_repo
tmpdir; bdir="$_LAST_TMPDIR"
make_build_dir "$bdir" tinyconfig x86_64
run_report "$bdir" "tinyconfig" "x86_64"
run_dir=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
txt=$(cat "$run_dir/summary.txt")
assert_not_contains "$txt" "Perf build:" "no Perf build line when file absent"

finish
