#!/bin/bash
# CI test for tests/programs/arena-test — build verification and behavioral.
# Build: musl-gcc + musl-clang for x86_64; cross-arches skipped when absent.
# Behavioral: runs x86_64 static binary on the host; checks key=value output.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

AT_DIR="$REPO/tests/programs/arena-test"
AT_BIN="$AT_DIR/bin/x86_64/arena-test"
AT_SRC="$AT_DIR/arena-test.c"
AT_MK="$AT_DIR/Makefile"

# ── Prerequisites ─────────────────────────────────────────────────────────────

begin_test "at-source-present"
assert_file_exists "$AT_SRC" "arena-test.c present"
assert_file_exists "$AT_MK"  "Makefile present"

# ── Build verification ────────────────────────────────────────────────────────

begin_test "at-build"
if ! command -v musl-gcc &>/dev/null || ! command -v musl-clang &>/dev/null; then
    printf '  skip  musl-gcc/musl-clang not installed — skipping build tests\n'
    printf '        (install: sudo pacman -S musl  or  sudo apt-get install musl-tools)\n'
else
    tmpdir; BUILD_STDERR="$_LAST_TMPDIR/build-stderr.txt"
    if make -C "$AT_DIR" clean all 2>"$BUILD_STDERR"; then
        pass "GCC + Clang build: zero warnings, all binaries produced"
        assert_file_exists "$AT_BIN"                              "x86_64 GCC binary present"
        assert_file_exists "$AT_DIR/bin/x86_64/arena-test-clang" "x86_64 Clang quality-gate binary present"
    else
        fail "build failed — compiler output:"
        cat "$BUILD_STDERR" >&2
    fi
fi

# Cross-arch skip notices (informational only, not assertions).
begin_test "at-cross-compilers"
missing=''
for cc in aarch64-linux-gnu-gcc riscv64-linux-gnu-gcc; do
    command -v "$cc" &>/dev/null || missing="$missing $cc"
done
if [[ -n "$missing" ]]; then
    printf '  skip  cross-compilers not installed:%s — arm64/riscv binaries not built\n' "$missing"
    printf '        (install: sudo apt-get install gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu)\n'
    pass "cross-compiler notice logged"
else
    pass "all cross-compilers present"
fi

# ── Behavioral: run x86_64 binary, verify key=value output ───────────────────

begin_test "at-binary-available"
if [[ ! -x "$AT_BIN" ]]; then
    printf '  skip  arena-test x86_64 binary absent — run: make bootstrap\n'
    exit 0
fi
pass "arena-test x86_64 binary present and executable"

begin_test "at-behavior-output"
tmpdir; AT_OUT="$_LAST_TMPDIR/arena-test.out"

if "$AT_BIN" >"$AT_OUT" 2>&1; then
    pass "exit 0: all internal tests passed"
else
    fail "non-zero exit: arena-test reported a failure"
fi

for key in alloc_ok readback_ok reset_ok reset_cycles align_ok align_bytes \
           page_size page_ok stress_ok stress_readback_ok stress_blocks \
           mmap_ok mmap_pages overall; do
    if grep -q "^${key}=" "$AT_OUT" 2>/dev/null; then
        pass "key present: $key"
    else
        fail "key missing: $key"
    fi
done

if grep -q "^overall=PASS$" "$AT_OUT" 2>/dev/null; then
    pass "overall=PASS"
else
    fail "overall not PASS — output:"
    cat "$AT_OUT" >&2
fi

begin_test "at-verbose-gate"
tmpdir; VERBOSE_OUT="$_LAST_TMPDIR/verbose.out"
VERBOSE=1 "$AT_BIN" >"$VERBOSE_OUT" 2>&1 || true
if grep -q "TEST:" "$VERBOSE_OUT" 2>/dev/null; then
    pass "VERBOSE=1: debug output present"
else
    fail "VERBOSE=1: expected debug TEST: lines not found"
fi

tmpdir; QUIET_OUT="$_LAST_TMPDIR/quiet.out"
"$AT_BIN" >"$QUIET_OUT" 2>&1 || true
if grep -q "TEST:" "$QUIET_OUT" 2>/dev/null; then
    fail "VERBOSE unset: debug TEST: lines appeared in output (should be hidden)"
else
    pass "VERBOSE unset: no debug output"
fi

finish
