#!/bin/bash
# CI test for tests/programs/serial-capture — build verification, behavioral,
# SIGTERM latency, and baud rejection. No hardware required.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

SC_DIR="$REPO/tests/programs/serial-capture"
SC_BIN="$SC_DIR/bin/serial-capture"
SC_SRC="$SC_DIR/serial-capture.c"
SC_MK="$SC_DIR/Makefile"

# ── Prerequisites ─────────────────────────────────────────────────────────────

begin_test "sc-source-present"
assert_file_exists "$SC_SRC"   "serial-capture.c present"
assert_file_exists "$SC_MK"    "Makefile present"

# ── Build verification ────────────────────────────────────────────────────────

begin_test "sc-build"
if ! command -v musl-gcc &>/dev/null || ! command -v musl-clang &>/dev/null; then
    printf '  skip  musl-gcc/musl-clang not installed — skipping build tests\n'
    printf '        (install: sudo pacman -S musl  or  sudo apt-get install musl-tools)\n'
else
    tmpdir; BUILD_STDERR="$_LAST_TMPDIR/build-stderr.txt"
    if make -C "$SC_DIR" clean all 2>"$BUILD_STDERR"; then
        pass "GCC + Clang build: zero warnings, both binaries produced"
        assert_file_exists "$SC_DIR/bin/serial-capture-gcc" "GCC quality-gate binary present"
        assert_file_exists "$SC_BIN"                        "Clang binary (shipped) present"
    else
        fail "build failed — compiler output:"
        cat "$BUILD_STDERR" >&2
    fi
fi

# ── socat-dependent tests (behavioral, SIGTERM) ───────────────────────────────

begin_test "sc-socat-available"
if ! command -v socat &>/dev/null; then
    printf '  skip  socat not installed — skipping behavioral tests\n'
    printf '        (install: sudo apt-get install socat  or: make bootstrap)\n'
    exit 0
fi
if [[ ! -x "$SC_BIN" ]]; then
    printf '  skip  serial-capture binary absent — run: make bootstrap\n'
    exit 0
fi
pass "socat and serial-capture binary available"

# ── Helper: create a socat pty pair (sets SC_TX and SC_RX) ───────────────────

SC_TX='' SC_RX='' SC_SOCAT_PID=''
start_pty_pair() {
    tmpdir
    SC_TX="$_LAST_TMPDIR/tx"
    SC_RX="$_LAST_TMPDIR/rx"
    socat PTY,link="$SC_TX",rawer PTY,link="$SC_RX",rawer &
    SC_SOCAT_PID=$!
    local count=0
    while [[ ! -e "$SC_TX" || ! -e "$SC_RX" ]]; do
        sleep 0.05
        (( count++ )) || true
        if [[ $count -ge 40 ]]; then
            kill "$SC_SOCAT_PID" 2>/dev/null || true
            fail "socat pty pair did not appear within 2s"
            return 1
        fi
    done
}

stop_pty_pair() {
    kill "$SC_SOCAT_PID" 2>/dev/null || true
    wait "$SC_SOCAT_PID" 2>/dev/null || true
    SC_SOCAT_PID=''
}

# Poll until <path> exists or 2s elapse. Returns 1 on timeout (caller cleans up).
wait_for_logfile() {
    local path="$1" label="$2"
    local count=0
    while [[ ! -e "$path" ]]; do
        sleep 0.05
        (( count++ )) || true
        if [[ $count -ge 40 ]]; then
            fail "$label: logfile did not appear within 2s"
            return 1
        fi
    done
}

# ── Behavioral: bytes written to pty appear verbatim in logfile ──────────────

begin_test "sc-behavior-data"
SC_PID=''
start_pty_pair
tmpdir; LOGFILE="$_LAST_TMPDIR/capture.log"

"$SC_BIN" "$SC_RX" 115200 "$LOGFILE" &
SC_PID=$!

if wait_for_logfile "$LOGFILE" "sc-behavior-data"; then
    # Write a known ASCII payload directly to the tx side (no $() — avoids
    # shell variable binary limitations; ASCII is sufficient for a capture test).
    printf 'serial-capture-data-integrity-test-ABCDEFGHIJ-0123456789\n' > "$SC_TX"
    sleep 0.2  # allow the capture loop to drain the pty buffer
    kill -TERM "$SC_PID" 2>/dev/null || true
    wait "$SC_PID" 2>/dev/null || true
    stop_pty_pair
    if grep -qF 'serial-capture-data-integrity-test-ABCDEFGHIJ-0123456789' "$LOGFILE" 2>/dev/null; then
        pass "data integrity: captured bytes match payload"
    else
        fail "data integrity: expected payload not found in logfile"
    fi
else
    kill "$SC_PID" 2>/dev/null || true
    stop_pty_pair
fi

# ── SIGTERM latency: process exits promptly (no VTIME polling delay) ──────────

begin_test "sc-sigterm-latency"
SC_PID=''
start_pty_pair
tmpdir; LOGFILE2="$_LAST_TMPDIR/capture2.log"

"$SC_BIN" "$SC_RX" 115200 "$LOGFILE2" &
SC_PID=$!

if wait_for_logfile "$LOGFILE2" "sc-sigterm-latency"; then
    sleep 0.1  # ensure it is blocked in read()
    kill -TERM "$SC_PID" 2>/dev/null || true

    # Poll for exit; allow up to 1s (sigaction should deliver in <100ms).
    exited=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$SC_PID" 2>/dev/null; then
            exited=1
            break
        fi
        sleep 0.1
    done

    wait "$SC_PID" 2>/dev/null || true
    stop_pty_pair

    if [[ $exited -eq 1 ]]; then
        pass "SIGTERM: process exited within 1s (sigaction, no VTIME polling)"
    else
        kill -KILL "$SC_PID" 2>/dev/null || true
        fail "SIGTERM: process still running after 1s"
    fi
else
    kill "$SC_PID" 2>/dev/null || true
    stop_pty_pair
fi

# ── Baud rate rejection ───────────────────────────────────────────────────────

begin_test "sc-baud-rejection"
tmpdir; BAUD_STDERR="$_LAST_TMPDIR/baud-stderr.txt"

# Non-numeric baud: strtol() catches this before opening the device.
if ! "$SC_BIN" /dev/null abc /dev/null 2>"$BAUD_STDERR"; then
    ERRMSG="$(cat "$BAUD_STDERR")"
    if [[ "$ERRMSG" == *"invalid baud rate"* ]]; then
        pass "non-numeric baud: non-zero exit with 'invalid baud rate' message"
    else
        fail "non-numeric baud: non-zero exit but wrong error: $ERRMSG"
    fi
else
    fail "non-numeric baud: expected non-zero exit, got 0"
fi

# Numeric but unsupported baud: baud_to_speed() catches this.
if ! "$SC_BIN" /dev/null 99 /dev/null 2>"$BAUD_STDERR"; then
    ERRMSG="$(cat "$BAUD_STDERR")"
    if [[ "$ERRMSG" == *"unsupported baud rate"* ]]; then
        pass "unsupported baud 99: non-zero exit with 'unsupported baud rate' message"
    else
        fail "unsupported baud 99: non-zero exit but wrong error: $ERRMSG"
    fi
else
    fail "unsupported baud 99: expected non-zero exit, got 0"
fi

finish
