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
# Clear ring buffer so pre-existing host dmesg noise doesn't trip issue detection.
# Requires CAP_SYSLOG — silently skipped when unavailable.
dmesg -C 2>/dev/null || true
if "$SN_BIN" >"$SN_OUT" 2>&1; then
    SN_EXIT=0
else
    SN_EXIT=$?
fi
if [[ $SN_EXIT -eq 255 ]]; then
    fail "infrastructure failure (exit 255) — output:"
    cat "$SN_OUT" >&2
else
    pass "exit $SN_EXIT (no infrastructure failure)"
fi

begin_test "sn-structure"
if grep -q "^\*\* SNAPSHOT \*\*" "$SN_OUT" 2>/dev/null; then
    pass "SNAPSHOT header present"
else
    fail "SNAPSHOT header missing"
fi
for field in HOSTNAME UNAME INIT UPTIME LOADAVG MEMORY KERNELMEM HUGEPAGES SWAP PAGESIZE CPU FLAGS CLOCKSOURCE FS USER LSM ASLR DMESG_RESTRICT KPTR_RESTRICT SCHEDSTATS CGROUP_CTRL ENTROPY TAINTED CMDLINE DMESG ISSUES; do
    if grep -q "${field}:" "$SN_OUT" 2>/dev/null; then
        pass "field present: $field"
    else
        fail "field missing: $field"
    fi
done

begin_test "sn-issues"
# Verify ISSUES field is present and exit code matches the clamped issue count.
issues_val=$(grep 'ISSUES:' "$SN_OUT" 2>/dev/null | grep -o '[0-9]*$' | head -1 || true)
if [[ -z "$issues_val" ]]; then
    fail "ISSUES field not found"
else
    pass "ISSUES: $issues_val present"
    if [[ $issues_val -gt 254 ]]; then
        expected_exit=254
    else
        expected_exit=$issues_val
    fi
    if [[ $SN_EXIT -eq $expected_exit ]]; then
        pass "exit code matches ISSUES count (exit=$SN_EXIT issues=$issues_val)"
    else
        fail "exit code mismatch: got $SN_EXIT, expected $expected_exit (ISSUES: $issues_val)"
    fi
fi

begin_test "sn-dmesg-format"
# When CAP_SYSLOG is unavailable, DMESG shows "skip:" — only check format then.
if grep -q 'DMESG:.*skip:' "$SN_OUT" 2>/dev/null; then
    pass "DMESG: CAP_SYSLOG unavailable — format check skipped"
else
    if grep -q 'DMESG:.*rcu_stall=' "$SN_OUT" 2>/dev/null; then
        pass "DMESG field contains rcu_stall counter"
    else
        fail "DMESG field missing rcu_stall counter"
        grep 'DMESG:' "$SN_OUT" >&2 || true
    fi
    if grep -q 'DMESG:.*lockup=' "$SN_OUT" 2>/dev/null; then
        pass "DMESG field contains lockup counter"
    else
        fail "DMESG field missing lockup counter"
    fi
fi

begin_test "sn-taint-format"
# Clean kernel: "TAINTED: 0" — tainted kernel: "TAINTED: N (FLAG ...)"
if grep -q 'TAINTED:.*[0-9]' "$SN_OUT" 2>/dev/null; then
    pass "TAINTED field has numeric value"
else
    fail "TAINTED field missing or malformed"
    grep 'TAINTED:' "$SN_OUT" >&2 || true
fi

finish
