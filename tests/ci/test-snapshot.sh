#!/bin/bash
# CI test for tests/programs/snapshot — build verification and behavioral.
# Build: musl-gcc + musl-clang for x86_64; cross-arches skipped when absent.
# Behavioral: runs x86_64 binary on host, validates section headers + exit marker.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

SN_DIR="$REPO/tests/programs/snapshot"
SN_BIN="$SN_DIR/bin/x86_64/snapshot"
SN_SRC="$SN_DIR/snapshot.c"
SN_MK="$SN_DIR/Makefile"

# ── Prerequisites ─────────────────────────────────────────────────────────────

begin_test "sn-source-present"
assert_file_exists "$SN_SRC" "snapshot.c present"
assert_file_exists "$SN_MK"  "Makefile present"

# ── Build verification ────────────────────────────────────────────────────────

begin_test "sn-build"
if ! command -v musl-gcc &>/dev/null || ! command -v musl-clang &>/dev/null; then
    printf '  skip  musl-gcc/musl-clang not installed — skipping build tests\n'
    printf '        (install: sudo pacman -S musl  or  sudo apt-get install musl-tools)\n'
else
    tmpdir; BUILD_STDERR="$_LAST_TMPDIR/build-stderr.txt"
    if make -C "$SN_DIR" clean all 2>"$BUILD_STDERR"; then
        pass "GCC + Clang build: zero warnings, all binaries produced"
        assert_file_exists "$SN_BIN"                           "x86_64 GCC binary present"
        assert_file_exists "$SN_DIR/bin/x86_64/snapshot-clang" "x86_64 Clang quality-gate binary present"
    else
        fail "build failed — compiler output:"
        cat "$BUILD_STDERR" >&2
    fi
fi

# Cross-arch skip notices (informational only).
begin_test "sn-cross-compilers"
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

# ── Behavioral: run x86_64 binary, validate output structure ─────────────────

begin_test "sn-binary-available"
if [[ ! -x "$SN_BIN" ]]; then
    printf '  skip  snapshot x86_64 binary absent — run: make bootstrap\n'
    finish
    exit 0
fi
pass "snapshot x86_64 binary present and executable"

begin_test "sn-run"
tmpdir; SN_OUT="$_LAST_TMPDIR/snapshot.out"
if "$SN_BIN" >"$SN_OUT" 2>&1; then
    pass "exit 0"
else
    fail "non-zero exit — output:"
    cat "$SN_OUT" >&2
fi

begin_test "sn-structure"
for section in SNAPSHOT UNAME UPTIME CMDLINE TAINTED DMESG MEMINFO; do
    if grep -q "^=== ${section} ===" "$SN_OUT" 2>/dev/null; then
        pass "section present: $section"
    else
        fail "section missing: $section"
    fi
done

begin_test "sn-clean-exit"
if grep -q "^snapshot_ok=1" "$SN_OUT" 2>/dev/null; then
    pass "snapshot_ok=1 present"
else
    fail "snapshot_ok=1 missing (binary may have crashed before completion)"
    cat "$SN_OUT" >&2
fi

finish
