#!/bin/bash
# Tests for the ns-time vDSO seqlock fix (QEMU 11.x riscv TCG hang).
# Strategy:
#   1. Static grep — verify cmd_offset() uses syscall(SYS_clock_gettime, ...)
#      not bare clock_gettime(), so the vDSO bypass is actually in the binary.
#   2. x86_64 integration — run ns-time-gcc offset end-to-end; assert exit 0
#      and "+100s offset applied ok" in output. Skip gracefully when
#      CLONE_NEWTIME is not permitted on the host (no CAP_SYS_ADMIN).
#   3. shellcheck — this file is clean.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

NS_TIME_GCC="$REPO/tests/ns/bin/x86_64/ns-time-gcc"
NS_TIME_SRC="$REPO/tests/ns/ns-time.c"

# ── Static analysis ───────────────────────────────────────────────────────────

begin_test "ns-time.c: cmd_offset child uses syscall(SYS_clock_gettime, ...) not clock_gettime()"
# Extract only the cmd_offset function body and verify the syscall form is present.
# Fail if the bare clock_gettime() call is still there (would spin under QEMU 11.x).
if grep -A 80 'static int cmd_offset' "$NS_TIME_SRC" | grep -q 'syscall(SYS_clock_gettime'; then
    pass "syscall(SYS_clock_gettime, ...) present in cmd_offset"
else
    fail "syscall(SYS_clock_gettime, ...) not found — vDSO bypass missing"
fi

begin_test "ns-time.c: cmd_offset child has no bare clock_gettime() call"
# The bare clock_gettime() was the hang trigger; it must not appear in cmd_offset.
bare_count=$(grep -A 80 'static int cmd_offset' "$NS_TIME_SRC" \
    | grep -c 'clock_gettime(CLOCK_MONOTONIC' || true)
if [[ "$bare_count" -eq 0 ]]; then
    pass "no bare clock_gettime(CLOCK_MONOTONIC) in cmd_offset"
else
    fail "bare clock_gettime(CLOCK_MONOTONIC) still present in cmd_offset ($bare_count occurrences)"
fi

begin_test "ns-time.c: sys/syscall.h is included"
grep -q '#include <sys/syscall.h>' "$NS_TIME_SRC" \
    && pass "sys/syscall.h included" || fail "sys/syscall.h not included"

# ── x86_64 integration ────────────────────────────────────────────────────────

begin_test "ns-time offset: binary exists (make programs required)"
[[ -x "$NS_TIME_GCC" ]] \
    && pass "ns-time-gcc binary present" \
    || fail "ns-time-gcc not found at $NS_TIME_GCC — run: make programs"

begin_test "ns-time offset: exit 0 and reports +100s offset on x86_64"
if [[ ! -x "$NS_TIME_GCC" ]]; then
    fail "binary absent — cannot run integration test"
else
    out=$("$NS_TIME_GCC" offset 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        if [[ "$out" == *"+100s offset applied ok"* ]]; then
            pass "ns-time offset: exit 0, '+100s offset applied ok' in output"
        else
            fail "ns-time offset: exit 0 but expected output not found (got: $out)"
        fi
    elif [[ "$out" == *"Operation not permitted"* ]] || \
         [[ "$out" == *"EPERM"* ]]; then
        # CLONE_NEWTIME requires CAP_SYS_ADMIN on some hosts; not a test failure.
        pass "ns-time offset: skip — CLONE_NEWTIME not permitted on this host (needs CAP_SYS_ADMIN)"
    else
        fail "ns-time offset: exited $rc, unexpected error: $out"
    fi
fi

begin_test "ns-time setns-mt: exit 0 on x86_64 (regression guard)"
if [[ ! -x "$NS_TIME_GCC" ]]; then
    fail "binary absent — cannot run integration test"
else
    out=$("$NS_TIME_GCC" setns-mt 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        pass "ns-time setns-mt: exit 0"
    elif [[ "$out" == *"Operation not permitted"* ]] || \
         [[ "$out" == *"EPERM"* ]] || \
         [[ "$out" == *"SKIP"* ]]; then
        pass "ns-time setns-mt: skip — not permitted or skipped on this host"
    else
        fail "ns-time setns-mt: exited $rc, unexpected error: $out"
    fi
fi

# ── shellcheck ────────────────────────────────────────────────────────────────

begin_test "shellcheck: test-ns-time-fix.sh"
shellcheck --severity=warning "$REPO/tests/ci/test-ns-time-fix.sh" \
    && pass "shellcheck clean" || fail "shellcheck errors"

finish
