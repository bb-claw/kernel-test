#!/bin/bash
# CI test for make valgrind infrastructure: scripts/valgrind.sh, valgrind.supp,
# and each program's scan/valgrind Makefile targets and build.
# Does NOT run valgrind itself — too slow and local-only; covered by make valgrind.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

VG_SCRIPT="$REPO/scripts/valgrind.sh"
VG_SUPP="$REPO/tests/programs/valgrind.supp"
PROGS_DIR="$REPO/tests/programs"
PROGS=(arena-test perf-event syscall-tests snapshot serial-capture)

# ── Infrastructure files ──────────────────────────────────────────────────────

begin_test "vg-script-present"
assert_file_exists "$VG_SCRIPT" "scripts/valgrind.sh present"
if [[ -x "$VG_SCRIPT" ]]; then pass "scripts/valgrind.sh is executable"
else fail "scripts/valgrind.sh is not executable"; fi

begin_test "vg-supp-present"
assert_file_exists "$VG_SUPP" "valgrind.supp present"
SUPP_COUNT="$(grep -c '^{$' "$VG_SUPP")"
if [[ "$SUPP_COUNT" -ge 8 ]]; then
    pass "valgrind.supp: $SUPP_COUNT suppression blocks (expected ≥8)"
else
    fail "valgrind.supp: $SUPP_COUNT suppression blocks (expected ≥8)"
fi

# ── Makefile targets present ──────────────────────────────────────────────────

begin_test "vg-makefile-targets"
for prog in "${PROGS[@]}"; do
    mk="$PROGS_DIR/$prog/Makefile"
    if [[ ! -f "$mk" ]]; then
        fail "$prog: Makefile missing"; continue
    fi
    if grep -q '^scan:'     "$mk"; then pass "$prog: scan target present"
    else fail "$prog: scan target missing"; fi
    if grep -q '^valgrind:' "$mk"; then pass "$prog: valgrind target present"
    else fail "$prog: valgrind target missing"; fi
    if grep -q '\-fanalyzer' "$mk"; then pass "$prog: -fanalyzer in CFLAGS_VALGRIND"
    else fail "$prog: -fanalyzer missing from CFLAGS_VALGRIND"; fi
done

# ── Valgrind build (glibc/static, x86_64; requires gcc) ──────────────────────

begin_test "vg-valgrind-build"
if ! command -v gcc &>/dev/null; then
    printf '  skip  gcc not installed — skipping valgrind build\n'
else
    for prog in "${PROGS[@]}"; do
        tmpdir; BUILD_ERR="$_LAST_TMPDIR/${prog}-vg.err"
        if make -C "$PROGS_DIR/$prog" valgrind 2>"$BUILD_ERR"; then
            pass "$prog: valgrind build: zero warnings"
        else
            fail "$prog: valgrind build failed:"
            cat "$BUILD_ERR" >&2
        fi
    done
    # Verify expected binary locations.
    assert_file_exists "$PROGS_DIR/arena-test/bin/x86_64/arena-test-valgrind"        "arena-test-valgrind binary"
    assert_file_exists "$PROGS_DIR/perf-event/bin/x86_64/perf-event-valgrind"        "perf-event-valgrind binary"
    assert_file_exists "$PROGS_DIR/syscall-tests/bin/x86_64/syscall-tests-valgrind"  "syscall-tests-valgrind binary"
    assert_file_exists "$PROGS_DIR/snapshot/bin/x86_64/snapshot-valgrind"            "snapshot-valgrind binary"
    assert_file_exists "$PROGS_DIR/serial-capture/bin/serial-capture-valgrind"       "serial-capture-valgrind binary"
fi

# ── Clang static analyzer scan ────────────────────────────────────────────────

begin_test "vg-scan"
if ! command -v clang &>/dev/null; then
    printf '  skip  clang not installed — skipping scan\n'
else
    for prog in "${PROGS[@]}"; do
        tmpdir; SCAN_ERR="$_LAST_TMPDIR/${prog}-scan.err"
        if make -C "$PROGS_DIR/$prog" scan 2>"$SCAN_ERR"; then
            pass "$prog: scan PASS (no analyzer findings)"
        else
            fail "$prog: scan FAIL (analyzer found issues):"
            cat "$SCAN_ERR" >&2
        fi
    done
fi

finish
