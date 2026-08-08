#!/bin/bash
# Capture serial output from a real board; equivalent of lib/vm.sh for hardware.
# Usage: board.sh <config> <arch>
# Env:   BUILD_DIR  TIMEOUT  BOARD_TTY (default /dev/ttyUSB0)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/lib/common.sh"

CONFIG=${1:?usage: board.sh <config> <arch>}
ARCH=${2:?usage: board.sh <config> <arch>}

require_env BUILD_DIR TIMEOUT

BOARD_TTY=${BOARD_TTY:-/dev/ttyUSB0}
OUT_DIR="$BUILD_DIR/$CONFIG-$ARCH"
DMESG_FILE="$OUT_DIR/dmesg.txt"
STATUS_FILE="$OUT_DIR/vm.status"

mkdir -p "$OUT_DIR"
rm -f "$DMESG_FILE"

[[ -e "$BOARD_TTY" ]] || die "BOARD_TTY=$BOARD_TTY does not exist — is the USB-UART dongle connected?"
[[ -c "$BOARD_TTY" ]] \
    || warn "BOARD_TTY=$BOARD_TTY is not a character device — proceeding (may be a socat pty symlink)"

# ── board_reset: CH340 USB relay pulse ────────────────────────────────────────
# Pulses the relay connected to the board's RST pin via HW_RELAY device.
# CH340-based relay protocol: relay-1 ON = 0xa0 0x01 0x01 0xa2
#                              relay-1 OFF = 0xa0 0x01 0x00 0xa1
# HW_RELAY defaults to /dev/vf2-relay (stable udev symlink from make hw-bootstrap).
# Falls back to a manual-reset warning when the device is absent.
board_reset() {
    local relay="${HW_RELAY:-/dev/vf2-relay}"
    if [[ ! -e "$relay" ]]; then
        warn "board_reset: $relay not found — reset the board manually"
        warn "  Run 'make hw-bootstrap' to install the udev rule, then replug the USB relay"
        return 0
    fi
    if [[ ! -w "$relay" ]]; then
        warn "board_reset: $relay not writable — check udev rule and dialout/uucp group membership"
        warn "  Manual power-on required"
        return 0
    fi
    # Bail if relay and BOARD_TTY are the same device: writing CH340 relay bytes to the
    # UART sends protocol garbage to the board's serial RX and does not cut power.
    local relay_real tty_real
    relay_real=$(realpath "$relay" 2>/dev/null || true)
    tty_real=$(realpath "${BOARD_TTY:-}" 2>/dev/null || true)
    if [[ -n "$relay_real" && "$relay_real" == "$tty_real" ]]; then
        warn "board_reset: relay ($relay) is the same device as BOARD_TTY — no separate power relay"
        warn "  Fix: set HW_RELAY_VID/HW_RELAY_PID in local.mk to match a dedicated relay device"
        warn "  Until then: power the board on manually before make hw-test"
        return 0
    fi
    info "board_reset: pulsing relay via $relay"
    if ! printf '\xa0\x01\x01\xa2' > "$relay"; then
        warn "board_reset: relay ON write failed — board may be stuck; manual reset required"
        return 0
    fi
    sleep 0.5
    if ! printf '\xa0\x01\x00\xa1' > "$relay"; then
        warn "board_reset: relay OFF write failed — RST pin may still be held; manual toggle required"
        return 0
    fi
    info "board_reset: relay pulsed — board is resetting"
}

# ── Capture backend selection ─────────────────────────────────────────────────
# Prefer the C binary (proper termios: O_NOCTTY, tcflush, fdatasync, binary-safe).
# Fall back to Bash stty+read when the binary is absent (e.g. make bootstrap not run).
SERIAL_CAPTURE="${SERIAL_CAPTURE:-$REPO_ROOT/tests/programs/serial-capture/bin/serial-capture}"

board_reset

VM_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VM_START_EPOCH=$(date -u +%s)
TIMED_OUT=0
PRE_BOOT_TIMEOUT=${HW_PRE_BOOT_TIMEOUT:-90}
DEADLINE=$(( VM_START_EPOCH + TIMEOUT ))  # Bash fallback path uses this directly

if [[ -x "$SERIAL_CAPTURE" ]]; then
    info "Capturing serial from $BOARD_TTY via serial-capture → $DMESG_FILE"
    info "(pre-boot: up to ${PRE_BOOT_TIMEOUT}s for U-Boot; test run: ${TIMEOUT}s)"

    CAPTURE_PID=''
    cleanup_capture() { [[ -n ${CAPTURE_PID:-} ]] && kill "$CAPTURE_PID" 2>/dev/null || true; }
    trap cleanup_capture EXIT

    "$SERIAL_CAPTURE" "$BOARD_TTY" 115200 "$DMESG_FILE" &
    CAPTURE_PID=$!

    # Phase 1: wait for U-Boot banner.  Without a relay the board auto-reboots after
    # each test run; this lets make hw-test catch the *next* fresh boot even if the
    # board is currently mid-test-run.  With a working relay, U-Boot appears within
    # a few seconds of board_reset().
    PRE_BOOT_DEADLINE=$(( VM_START_EPOCH + PRE_BOOT_TIMEOUT ))
    while true; do
        if grep -qF 'U-Boot' "$DMESG_FILE" 2>/dev/null; then break; fi
        remaining=$(( PRE_BOOT_DEADLINE - $(date -u +%s) ))
        if [[ $remaining -le 0 ]]; then
            warn "U-Boot not detected within ${PRE_BOOT_TIMEOUT}s — is the board powered on?"
            TIMED_OUT=1; break
        fi
        sleep 0.5
    done

    # Phase 2: wait for TEST_DONE within HW_TIMEOUT of U-Boot appearing.
    if [[ $TIMED_OUT -eq 0 ]]; then
        DEADLINE=$(( $(date -u +%s) + TIMEOUT ))
        info "U-Boot detected — test timeout: ${TIMEOUT}s"
        while true; do
            remaining=$(( DEADLINE - $(date -u +%s) ))
            if [[ $remaining -le 0 ]]; then TIMED_OUT=1; break; fi
            grep -qF 'TEST_DONE' "$DMESG_FILE" 2>/dev/null && break
            sleep 0.5
        done
    fi

    kill "$CAPTURE_PID" 2>/dev/null || true
    wait "$CAPTURE_PID" 2>/dev/null || true
    CAPTURE_PID=''
else
    warn "serial-capture binary absent — using Bash read fallback (run: make bootstrap)"

    # stty on a socat pty silently accepts the call (baud rate is a no-op on ptys).
    if ! stty -F "$BOARD_TTY" 115200 cs8 -cstopb -parenb -crtscts raw -echo 2>/dev/null; then
        warn "stty: could not configure $BOARD_TTY — is the USB-UART dongle connected?"
    fi

    # Open TTY for read+write; write side kept for Phase 6 U-Boot command sending.
    exec 3<>"$BOARD_TTY"
    info "Capturing serial from $BOARD_TTY (Bash fallback, timeout: ${TIMEOUT}s) → $DMESG_FILE"

    while true; do
        remaining=$(( DEADLINE - $(date -u +%s) ))
        if [[ $remaining -le 0 ]]; then TIMED_OUT=1; break; fi
        read_limit=$(( remaining < 5 ? remaining : 5 ))
        if ! IFS= read -r -t "$read_limit" line <&3; then
            TIMED_OUT=1; break
        fi
        printf '%s\n' "$line" >> "$DMESG_FILE"
        [[ "$line" == *TEST_DONE* ]] && break
    done

    exec 3>&-
fi

VM_DURATION=$(( $(date -u +%s) - VM_START_EPOCH ))

# ── Parse, evaluate, record, and report ──────────────────────────────────────

parse_serial_output   "$DMESG_FILE"
determine_boot_status "$DMESG_FILE" 0 "$TIMED_OUT"
write_run_status      "$STATUS_FILE" "$VM_START_TIME" "$VM_DURATION"

log_run_result "$CONFIG / $ARCH (board: $BOARD_TTY)" || true

# Mirror vm.sh exit behavior: non-zero on any boot/test failure.
if [[ "$BOOT_STATUS" != PASS ]] || [[ $(( FAIL_COUNT + KUNIT_FAIL )) -gt 0 ]]; then
    exit 1
fi
