#!/bin/bash
# CI test for tests/programs/perf-event — build verification and behavioral.
# Build: musl-gcc + musl-clang for x86_64; cross-arches skipped when absent.
# Behavioral: runs x86_64 static binary; skips if perf_event_open is restricted.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

PE_DIR="$REPO/tests/programs/perf-event"
PE_BIN="$PE_DIR/bin/x86_64/perf-event"
PE_SRC="$PE_DIR/perf-event.c"
PE_MK="$PE_DIR/Makefile"

# ── Prerequisites ─────────────────────────────────────────────────────────────

begin_test "pe-source-present"
assert_file_exists "$PE_SRC" "perf-event.c present"
assert_file_exists "$PE_MK"  "Makefile present"

# ── Build verification ────────────────────────────────────────────────────────

begin_test "pe-build"
if ! command -v musl-gcc &>/dev/null || ! command -v musl-clang &>/dev/null; then
    printf '  skip  musl-gcc/musl-clang not installed — skipping build tests\n'
    printf '        (install: sudo pacman -S musl  or  sudo apt-get install musl-tools)\n'
else
    tmpdir; BUILD_STDERR="$_LAST_TMPDIR/build-stderr.txt"
    if make -C "$PE_DIR" clean all ARCHES="x86_64" 2>"$BUILD_STDERR"; then
        pass "GCC + Clang build: zero warnings, all binaries produced"
        assert_file_exists "$PE_BIN"                              "x86_64 GCC binary present"
        assert_file_exists "$PE_DIR/bin/x86_64/perf-event-clang" "x86_64 Clang quality-gate binary present"
    else
        fail "build failed — compiler output:"
        cat "$BUILD_STDERR" >&2
    fi
fi

# i386: separate build when gcc -m32 is available (requires gcc-multilib).
begin_test "pe-i386-build"
if command -v gcc &>/dev/null && gcc -m32 -x c -o /dev/null - </dev/null 2>/dev/null; then
    tmpdir; I386_STDERR="$_LAST_TMPDIR/pe-i386-stderr.txt"
    if make -C "$PE_DIR" "bin/i386/perf-event" 2>"$I386_STDERR"; then
        assert_file_exists "$PE_DIR/bin/i386/perf-event" "i386 binary built"
    else
        fail "i386 build failed — compiler output:"
        cat "$I386_STDERR" >&2
    fi
else
    printf '  skip  gcc -m32 not available — i386 binary not checked\n'
    pass "i386 cross-compile notice logged"
fi

# Cross-arch skip notices (informational only, not assertions).
begin_test "pe-cross-compilers"
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

# ── Behavioral: run x86_64 binary, verify output ─────────────────────────────

begin_test "pe-binary-available"
if [[ ! -x "$PE_BIN" ]]; then
    printf '  skip  perf-event x86_64 binary absent — run: make bootstrap\n'
    exit 0
fi
pass "perf-event x86_64 binary present and executable"

begin_test "pe-behavior-output"
# perf_event_open(PERF_TYPE_SOFTWARE) may be restricted by kernel.perf_event_paranoid.
# Soft-skip: if the binary exits non-zero with "perf_event_open" in stderr, treat as
# a kernel policy restriction rather than a code failure.
tmpdir
PE_OUT="$_LAST_TMPDIR/perf.out"
PE_ERR="$_LAST_TMPDIR/perf.err"

if "$PE_BIN" >"$PE_OUT" 2>"$PE_ERR"; then
    COUNT="$(cat "$PE_OUT")"
    if [[ "$COUNT" =~ ^[0-9]+$ ]] && [[ "$COUNT" -gt 0 ]]; then
        pass "exit 0: counter=$COUNT (> 0)"
    else
        fail "exit 0 but output is not a positive integer: $(cat "$PE_OUT")"
    fi
elif grep -q "perf_event_open" "$PE_ERR" 2>/dev/null; then
    PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || printf 'unknown')"
    printf '  skip  perf_event_open refused (kernel.perf_event_paranoid=%s) — skipping behavioral test\n' "$PARANOID"
    pass "perf_event_open restriction detected and handled"
else
    fail "non-zero exit for unexpected reason — stderr: $(cat "$PE_ERR")"
fi

finish
