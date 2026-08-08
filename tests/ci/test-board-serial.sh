#!/bin/bash
# CI test for lib/board.sh — replays fixtures through socat pty pairs, no hardware needed.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

BOARD_SH="$REPO/lib/board.sh"
FIXTURES="$REPO/tests/ci/fixtures/board"

# ── Prerequisites ─────────────────────────────────────────────────────────────

begin_test "board-sh-executable"
assert_file_exists "$BOARD_SH" "lib/board.sh present"
if [[ -x "$BOARD_SH" ]]; then pass "lib/board.sh executable"
else fail "lib/board.sh not executable"; fi

begin_test "board-fixtures-present"
assert_file_exists "$FIXTURES/transcript-pass.txt"       "transcript-pass.txt present"
assert_file_exists "$FIXTURES/transcript-panic.txt"      "transcript-panic.txt present"
assert_file_exists "$FIXTURES/transcript-boot-hang.txt"  "transcript-boot-hang.txt present"
assert_file_exists "$FIXTURES/transcript-uboot-hang.txt" "transcript-uboot-hang.txt present"

begin_test "board-socat-available"
if command -v socat &>/dev/null; then pass "socat available"
else
    printf '  skip  socat not installed — skipping board serial replay tests\n'
    printf '        (install: sudo apt-get install socat  or: make bootstrap)\n'
    finish
fi

begin_test "board-serial-capture-backend"
SC_BIN="$REPO/tests/programs/serial-capture/bin/serial-capture"
# Build serial-capture if gcc is available so CI exercises the C backend path.
if [[ ! -x "$SC_BIN" ]] && command -v gcc &>/dev/null; then
    make -C "$REPO/tests/programs/serial-capture" >/dev/null 2>&1 || true
fi
if [[ -x "$SC_BIN" ]]; then pass "serial-capture binary present — C backend active"
else pass "serial-capture binary absent — Bash fallback active (run: make bootstrap)"; fi

# ── Helper: run board.sh against a socat pty fed from a transcript ────────────
#
# run_board_replay <fixture> <build_dir> <timeout>
# Creates a socat pty pair, feeds <fixture> to the TX side, runs board.sh
# against the RX side, returns when board.sh exits.
# Sets global RBR_STATUS and RBR_DMESG to the produced file paths.
RBR_STATUS=''
RBR_DMESG=''
run_board_replay() {
    local fixture="$1" build_dir="$2" timeout_val="$3"
    local tx rx socat_pid wait_count board_pid
    # Clear globals so callers never see stale paths from a prior run.
    RBR_STATUS=''; RBR_DMESG=''

    tmpdir; local link_dir="$_LAST_TMPDIR"
    tx="$link_dir/tx"
    rx="$link_dir/rx"

    socat PTY,link="$tx",rawer PTY,link="$rx",rawer &
    socat_pid=$!

    # Wait for socat to create both pty symlinks (up to 2 s).
    wait_count=0
    while [[ ! -e "$tx" || ! -e "$rx" ]]; do
        sleep 0.1
        (( wait_count++ )) || true
        [[ $wait_count -lt 20 ]] || { kill "$socat_pid" 2>/dev/null || true; return 1; }
    done

    # Start board.sh in background so we can control when data arrives.
    BUILD_DIR="$build_dir" TIMEOUT="$timeout_val" BOARD_TTY="$rx" \
        bash "$BOARD_SH" vf2config riscv &
    board_pid=$!

    # Wait for the capture backend to open the pty and create the log file
    # (serial-capture opens the device before the log file, so log existence
    # means the pty is open; Bash fallback uses exec 3<> which is synchronous).
    local dmesg_path="$build_dir/vf2config-riscv/dmesg.txt"
    wait_count=0
    while [[ ! -e "$dmesg_path" ]]; do
        sleep 0.1
        (( wait_count++ )) || true
        [[ $wait_count -lt 20 ]] || break  # 2s ceiling
    done

    # Open TX and write transcript; keep TX fd open until board.sh finishes.
    # This prevents socat from exiting on EOF before the capture backend drains the buffer.
    exec 4>"$tx"
    cat "$fixture" >&4

    wait "$board_pid" || true
    exec 4>&-   # close TX only after board.sh is done

    kill "$socat_pid" 2>/dev/null || true
    wait "$socat_pid" 2>/dev/null || true

    RBR_STATUS="$build_dir/vf2config-riscv/vm.status"
    RBR_DMESG="$build_dir/vf2config-riscv/dmesg.txt"
}

# ── Test group: full-pass transcript ─────────────────────────────────────────

tmpdir; _bd_pass="$_LAST_TMPDIR"
run_board_replay "$FIXTURES/transcript-pass.txt" "$_bd_pass" 30
_status_pass=$(cat "$RBR_STATUS" 2>/dev/null || true)
_dmesg_pass=$(cat "$RBR_DMESG"  2>/dev/null || true)

begin_test "board-serial-pass-status-file"
assert_file_exists "$RBR_STATUS" "vm.status written"

begin_test "board-serial-pass-boot"
assert_contains "$_status_pass" "BOOT=PASS"    "BOOT=PASS"
assert_contains "$_status_pass" "TEST_DONE=1"  "TEST_DONE=1"

begin_test "board-serial-pass-failed-tests"
assert_contains "$_status_pass" "FAILED_TESTS="           "FAILED_TESTS line present"
assert_contains "$_status_pass" "100_network-loopback"    "100_network-loopback in FAILED_TESTS"

begin_test "board-serial-pass-timing"
assert_contains "$_status_pass" "START_TIME="  "START_TIME recorded"
assert_contains "$_status_pass" "DURATION="    "DURATION recorded"
dur=$(grep '^DURATION=' "$RBR_STATUS" | cut -d= -f2)
if [[ "$dur" -ge 0 ]] 2>/dev/null; then pass "DURATION is a non-negative integer"
else fail "DURATION is not numeric: '$dur'"; fi

begin_test "board-serial-pass-dmesg"
assert_file_exists "$RBR_DMESG" "dmesg.txt written"
assert_contains "$_dmesg_pass" "BOOT_OK:"                         "BOOT_OK marker in dmesg"
assert_contains "$_dmesg_pass" "TEST PASS: 001_smoke"             "TEST PASS 001_smoke in dmesg"
assert_contains "$_dmesg_pass" "TEST FAIL: 100_network-loopback"  "TEST FAIL in dmesg"
assert_contains "$_dmesg_pass" "KTAP version"                     "KTAP block in dmesg"
assert_contains "$_dmesg_pass" "TEST_DONE"                        "TEST_DONE in dmesg"

# ── Test group: kernel panic transcript ──────────────────────────────────────

tmpdir; _bd_panic="$_LAST_TMPDIR"
run_board_replay "$FIXTURES/transcript-panic.txt" "$_bd_panic" 5
_status_panic=$(cat "$RBR_STATUS" 2>/dev/null || true)

begin_test "board-serial-panic-status-file"
assert_file_exists "$RBR_STATUS" "vm.status written on panic"

begin_test "board-serial-panic-boot"
assert_contains     "$_status_panic" "BOOT=FAIL"  "BOOT=FAIL on kernel panic"
assert_not_contains "$_status_panic" "BOOT=PASS"  "not BOOT=PASS"

begin_test "board-serial-panic-fail-reason"
assert_contains "$_status_panic" "FAIL_REASON="          "FAIL_REASON set"
assert_contains "$_status_panic" "Kernel panic"          "Kernel panic literal in FAIL_REASON"

# ── Test group: board hang after BOOT_OK (stops mid-test, no TEST_DONE) ──────

tmpdir; _bd_hang="$_LAST_TMPDIR"
run_board_replay "$FIXTURES/transcript-boot-hang.txt" "$_bd_hang" 5
_status_hang=$(cat "$RBR_STATUS" 2>/dev/null || true)

begin_test "board-serial-hang-status-file"
assert_file_exists "$RBR_STATUS" "vm.status written on hang"

begin_test "board-serial-hang-boot"
assert_contains     "$_status_hang" "BOOT=FAIL"   "BOOT=FAIL when TEST_DONE missing"
assert_not_contains "$_status_hang" "BOOT=PASS"   "not BOOT=PASS"

begin_test "board-serial-hang-fail-reason"
assert_contains "$_status_hang" "FAIL_REASON="       "FAIL_REASON set on hang"
assert_contains "$_status_hang" "TEST_DONE not reached" "TEST_DONE not reached in reason"

# ── Test group: U-Boot hang (never reaches kernel, no BOOT_OK) ───────────────

tmpdir; _bd_uboot="$_LAST_TMPDIR"
run_board_replay "$FIXTURES/transcript-uboot-hang.txt" "$_bd_uboot" 5
_status_uboot=$(cat "$RBR_STATUS" 2>/dev/null || true)

begin_test "board-serial-uboot-hang-status-file"
assert_file_exists "$RBR_STATUS" "vm.status written on U-Boot hang"

begin_test "board-serial-uboot-hang-boot"
assert_contains     "$_status_uboot" "BOOT=FAIL"  "BOOT=FAIL when BOOT_OK never seen"
assert_not_contains "$_status_uboot" "BOOT=PASS"  "not BOOT=PASS"

begin_test "board-serial-uboot-hang-fail-reason"
assert_contains "$_status_uboot" "FAIL_REASON="      "FAIL_REASON set on U-Boot hang"
assert_contains "$_status_uboot" "Timeout"           "Timeout in FAIL_REASON"

# ── Test group: Bash fallback path (SERIAL_CAPTURE absent) ───────────────────
# Override SERIAL_CAPTURE to a nonexistent binary so board.sh uses stty+read.

tmpdir; _bd_bash="$_LAST_TMPDIR"
begin_test "board-serial-bash-fallback"
_bash_rc=0
SERIAL_CAPTURE=/nonexistent \
    run_board_replay "$FIXTURES/transcript-pass.txt" "$_bd_bash" 30 || _bash_rc=$?
_status_bash=$(cat "$RBR_STATUS" 2>/dev/null || true)
assert_file_exists "$RBR_STATUS"                     "vm.status written via Bash path"
assert_contains    "$_status_bash" "BOOT=PASS"       "BOOT=PASS via Bash path"
assert_contains    "$_status_bash" "TEST_DONE=1"     "TEST_DONE=1 via Bash path"
assert_contains    "$_status_bash" "TESTS_FAIL=1"    "TESTS_FAIL=1 via Bash path"

# ── Test: missing BOARD_TTY exits non-zero with clear error ──────────────────

begin_test "board-serial-missing-tty"
tmpdir; _bd_missing="$_LAST_TMPDIR"
rc=0
BUILD_DIR="$_bd_missing" TIMEOUT=5 BOARD_TTY="/tmp/ks-nonexistent-tty-$$" \
    bash "$BOARD_SH" vf2config riscv >/dev/null 2>&1 || rc=$?
if [[ $rc -ne 0 ]]; then pass "board.sh exits non-zero when BOARD_TTY missing (rc=$rc)"
else fail "board.sh should exit non-zero when BOARD_TTY does not exist"; fi

finish
