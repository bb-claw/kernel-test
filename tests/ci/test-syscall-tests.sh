#!/bin/bash
# CI test for tests/programs/syscall-tests — build verification and behavioral.
# Build: musl-gcc + musl-clang for x86_64; gcc -m32 for i386 if available.
# Behavioral: runs x86_64 static binary on the host for each subcommand.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

ST_DIR="$REPO/tests/programs/syscall-tests"
ST_BIN="$ST_DIR/bin/x86_64/syscall-tests"
ST_SRC="$ST_DIR/syscall-tests.c"
ST_MK="$ST_DIR/Makefile"

# ── Prerequisites ─────────────────────────────────────────────────────────────

begin_test "st-source-present"
assert_file_exists "$ST_SRC" "syscall-tests.c present"
assert_file_exists "$ST_MK"  "Makefile present"

# ── Build verification ────────────────────────────────────────────────────────

begin_test "st-build"
if ! command -v musl-gcc &>/dev/null || ! command -v musl-clang &>/dev/null; then
    printf '  skip  musl-gcc/musl-clang not installed — skipping build tests\n'
    printf '        (install: sudo pacman -S musl  or  sudo apt-get install musl-tools)\n'
else
    tmpdir; BUILD_STDERR="$_LAST_TMPDIR/build-stderr.txt"
    if make -C "$ST_DIR" clean all 2>"$BUILD_STDERR"; then
        pass "GCC + Clang build: zero warnings, all binaries produced"
        assert_file_exists "$ST_BIN"                                "x86_64 GCC binary present"
        assert_file_exists "$ST_DIR/bin/x86_64/syscall-tests-clang" "x86_64 Clang quality-gate binary present"
    else
        fail "build failed — compiler output:"
        cat "$BUILD_STDERR" >&2
    fi
fi

# i386 cross-compile smoke (informational)
begin_test "st-i386-build"
if command -v gcc &>/dev/null && gcc -m32 -x c -o /dev/null - </dev/null 2>/dev/null; then
    assert_file_exists "$ST_DIR/bin/i386/syscall-tests" "i386 binary built"
else
    printf '  skip  gcc -m32 not available — i386 binary not checked\n'
    pass "i386 cross-compile notice logged"
fi

# ── Behavioral: run each subcommand on host ───────────────────────────────────

begin_test "st-binary-available"
if [[ ! -x "$ST_BIN" ]]; then
    printf '  skip  syscall-tests x86_64 binary absent — run: make bootstrap\n'
    finish
fi
pass "syscall-tests x86_64 binary present and executable"

# Each subcommand must exit 0 (pass or skip) and not print any FAIL: line.
run_subcommand() {
    local subcmd="$1"
    begin_test "st-$subcmd"
    tmpdir; local out="$_LAST_TMPDIR/out.txt"
    if "$ST_BIN" "$subcmd" >"$out" 2>&1; then
        if grep -q '^FAIL:' "$out"; then
            fail "$subcmd: FAIL: line in output:"
            cat "$out" >&2
        else
            pass "$subcmd: exit 0, no FAIL: lines"
        fi
    else
        fail "$subcmd: non-zero exit"
        cat "$out" >&2
    fi
}

run_subcommand 32bit
run_subcommand seccomp
run_subcommand io_uring
run_subcommand fds
run_subcommand unix
run_subcommand landlock

# ── Missing subcommand ────────────────────────────────────────────────────────

begin_test "st-bad-subcommand"
if "$ST_BIN" bad_subcommand >/dev/null 2>&1; then
    fail "expected non-zero exit for unknown subcommand"
else
    pass "unknown subcommand exits non-zero"
fi

finish
