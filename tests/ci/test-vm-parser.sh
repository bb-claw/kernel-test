#!/bin/bash
# Tests for the shared serial output parser functions in lib/common.sh:
# parse_serial_output, determine_boot_status, write_run_status, log_run_result.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

FX="$REPO/tests/ci/fixtures/parser"

# ── parse_serial_output ───────────────────────────────────────────────────────

begin_test "parse: happy path — BOOT_OK, TEST_DONE, PASS/FAIL counts, FAILED_TESTS"
parse_serial_output "$FX/transcript-pass.txt"
assert_eq "$BOOT_OK"   "1" "BOOT_OK"
assert_eq "$TEST_DONE" "1" "TEST_DONE"
assert_eq "$PASS_COUNT" "3" "PASS_COUNT"
assert_eq "$FAIL_COUNT" "1" "FAIL_COUNT"
assert_eq "$TESTS_TOTAL" "4" "TESTS_TOTAL"
assert_contains "$FAILED_TESTS" "040_check-devnodes" "FAILED_TESTS"
assert_eq "$PANIC" "0" "PANIC absent"
assert_eq "$KUNIT_PASS" "0" "KUNIT_PASS absent"

begin_test "parse: kernel panic — PANIC=1, BOOT_OK=0"
parse_serial_output "$FX/transcript-panic.txt"
assert_eq "$PANIC"   "1" "PANIC"
assert_eq "$BOOT_OK" "0" "BOOT_OK"
assert_eq "$OOPS"    "0" "OOPS absent"

begin_test "parse: empty file — all counters zero"
parse_serial_output "$FX/transcript-timeout-qemu.txt"
assert_eq "$BOOT_OK"    "0" "BOOT_OK"
assert_eq "$PASS_COUNT" "0" "PASS_COUNT"
assert_eq "$KUNIT_PASS" "0" "KUNIT_PASS"

begin_test "parse: KTAP block — KUNIT_PASS=3, KUNIT_FAIL=3 (including suite summary)"
parse_serial_output "$FX/transcript-ktap.txt"
assert_eq "$KUNIT_PASS" "3" "KUNIT_PASS"
assert_eq "$KUNIT_FAIL" "3" "KUNIT_FAIL"
assert_eq "$BOOT_OK"    "1" "BOOT_OK"

begin_test "parse: KTAP block no timestamps — KUNIT_PASS=2, KUNIT_FAIL=3 (CONFIG_PRINTK_TIME=n)"
parse_serial_output "$FX/transcript-ktap-notimestamp.txt"
assert_eq "$KUNIT_PASS" "2" "KUNIT_PASS (no timestamps)"
assert_eq "$KUNIT_FAIL" "3" "KUNIT_FAIL (2 subtests + 1 suite summary, no timestamps)"
assert_eq "$BOOT_OK"    "1" "BOOT_OK"

begin_test "parse: CANARY marker present — CANARY_EARLY=reached (no CANARY=1 needed)"
CANARY=0 parse_serial_output "$FX/transcript-canary.txt"
assert_eq "$CANARY_EARLY" "reached" "CANARY_EARLY"

begin_test "parse: CANARY=1 but marker absent — CANARY_EARLY=missing"
CANARY=1 parse_serial_output "$FX/transcript-pass.txt"
assert_eq "$CANARY_EARLY" "missing" "CANARY_EARLY"

begin_test "parse: CANARY=0 and marker absent — CANARY_EARLY empty"
CANARY=0 parse_serial_output "$FX/transcript-pass.txt"
assert_eq "$CANARY_EARLY" "" "CANARY_EARLY empty"

# ── determine_boot_status ─────────────────────────────────────────────────────

begin_test "boot-status: PASS on clean boot with TEST_DONE"
parse_serial_output "$FX/transcript-pass.txt"
determine_boot_status "$FX/transcript-pass.txt" 0 0
assert_eq "$BOOT_STATUS" "PASS" "BOOT_STATUS"
assert_eq "$FAIL_REASON" ""     "FAIL_REASON empty"

begin_test "boot-status: FAIL on kernel panic with panic line in FAIL_REASON"
parse_serial_output "$FX/transcript-panic.txt"
determine_boot_status "$FX/transcript-panic.txt" 0 0
assert_eq "$BOOT_STATUS" "FAIL" "BOOT_STATUS"
assert_contains "$FAIL_REASON" "Kernel panic" "FAIL_REASON"
assert_contains "$FAIL_REASON" "Unable to mount root" "FAIL_REASON detail"

begin_test "boot-status: FAIL on QEMU timeout (exit_code=124)"
parse_serial_output "$FX/transcript-timeout-qemu.txt"
determine_boot_status "$FX/transcript-timeout-qemu.txt" 124 0
assert_eq "$BOOT_STATUS" "FAIL" "BOOT_STATUS"
assert_contains "$FAIL_REASON" "Timeout" "FAIL_REASON"

begin_test "boot-status: FAIL on board timeout (timeout_occurred=1)"
parse_serial_output "$FX/transcript-timeout-board.txt"
determine_boot_status "$FX/transcript-timeout-board.txt" 0 1
assert_eq "$BOOT_STATUS" "FAIL" "BOOT_STATUS"
assert_contains "$FAIL_REASON" "Timeout" "FAIL_REASON"

begin_test "boot-status: FAIL when TEST_DONE missing despite BOOT_OK"
tmpdir
printf 'BOOT_OK: kernel reached init\n> TEST RUN: 001_smoke\n' > "$_LAST_TMPDIR/partial.txt"
parse_serial_output "$_LAST_TMPDIR/partial.txt"
determine_boot_status "$_LAST_TMPDIR/partial.txt" 0 0
assert_eq "$BOOT_STATUS" "FAIL" "BOOT_STATUS"
assert_contains "$FAIL_REASON" "TEST_DONE" "FAIL_REASON"

# ── write_run_status ──────────────────────────────────────────────────────────

begin_test "write-status: writes all required KEY=VALUE fields"
tmpdir
parse_serial_output "$FX/transcript-pass.txt"
determine_boot_status "$FX/transcript-pass.txt" 0 0
write_run_status "$_LAST_TMPDIR/vm.status" "2026-08-06T10:00:00Z" 42
out=$(cat "$_LAST_TMPDIR/vm.status")
assert_contains "$out" "BOOT=PASS"           "BOOT field"
assert_contains "$out" "TESTS_PASS=3"        "TESTS_PASS"
assert_contains "$out" "TESTS_FAIL=1"        "TESTS_FAIL"
assert_contains "$out" "TESTS_TOTAL=4"       "TESTS_TOTAL"
assert_contains "$out" "START_TIME=2026-08-06T10:00:00Z" "START_TIME"
assert_contains "$out" "DURATION=42"         "DURATION"
assert_contains "$out" "FAILED_TESTS=040_check-devnodes" "FAILED_TESTS"
assert_not_contains "$out" "FAIL_REASON"     "no FAIL_REASON on PASS"

begin_test "write-status: FAIL_REASON written on failure"
tmpdir
parse_serial_output "$FX/transcript-panic.txt"
determine_boot_status "$FX/transcript-panic.txt" 0 0
write_run_status "$_LAST_TMPDIR/vm.status" "2026-08-06T10:00:00Z" 5
out=$(cat "$_LAST_TMPDIR/vm.status")
assert_contains "$out" "BOOT=FAIL"     "BOOT field"
assert_contains "$out" "FAIL_REASON="  "FAIL_REASON present"

begin_test "write-status: CANARY_EARLY written when reached"
tmpdir
CANARY=1 parse_serial_output "$FX/transcript-canary.txt"
determine_boot_status "$FX/transcript-canary.txt" 0 0
write_run_status "$_LAST_TMPDIR/vm.status" "2026-08-06T10:00:00Z" 10
out=$(cat "$_LAST_TMPDIR/vm.status")
assert_contains "$out" "CANARY_EARLY=reached" "CANARY_EARLY"

# ── log_run_result ────────────────────────────────────────────────────────────

begin_test "log-result: returns 0 on full PASS"
parse_serial_output "$FX/transcript-pass.txt"
determine_boot_status "$FX/transcript-pass.txt" 0 0
# Override FAIL_COUNT to 0 so all tests pass
FAIL_COUNT=0; PASS_COUNT=3; TESTS_TOTAL=3; FAILED_TESTS=''
rc=0; log_run_result "tinyconfig / x86_64" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "return code"

begin_test "log-result: returns 1 on PARTIAL (test failures)"
BOOT_STATUS=PASS; PASS_COUNT=2; FAIL_COUNT=1; TESTS_TOTAL=3
KUNIT_PASS=0; KUNIT_FAIL=0; FAILED_TESTS='040_check-devnodes'; FAIL_REASON=''
rc=0; log_run_result "tinyconfig / x86_64" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "return code"

begin_test "log-result: returns 1 on boot FAIL"
parse_serial_output "$FX/transcript-panic.txt"
determine_boot_status "$FX/transcript-panic.txt" 0 0
rc=0; log_run_result "tinyconfig / x86_64" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "return code"

begin_test "log-result: returns 1 on QEMU timeout"
parse_serial_output "$FX/transcript-timeout-qemu.txt"
determine_boot_status "$FX/transcript-timeout-qemu.txt" 124 0
rc=0; log_run_result "tinyconfig / x86_64" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "return code"

finish
