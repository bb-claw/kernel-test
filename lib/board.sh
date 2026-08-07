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

# ── board_reset: stub ─────────────────────────────────────────────────────────
# Phase 6 replaces this with a USB relay command.
board_reset() {
    warn "board_reset: stub — no hardware reset wired (Phase 6 adds USB relay)"
    warn "Manual action required: power-cycle or press RST on the board, then re-run"
}

# ── Configure TTY ─────────────────────────────────────────────────────────────
# stty on a socat pty silently accepts the call (baud rate is a no-op on ptys).
# On a missing or inaccessible device, stty fails; warn but let exec 3<> below
# give the definitive error with the actual device path.
if ! stty -F "$BOARD_TTY" 115200 cs8 -cstopb -parenb -crtscts raw -echo 2>/dev/null; then
    warn "stty: could not configure $BOARD_TTY — is the USB-UART dongle connected?"
fi

# Open TTY for read+write: write side kept open for Phase 6 U-Boot command sending.
exec 3<>"$BOARD_TTY"

info "Capturing serial from $BOARD_TTY (timeout: ${TIMEOUT}s) → $DMESG_FILE"

VM_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VM_START_EPOCH=$(date -u +%s)

# ── Line-by-line read with wall-clock deadline ────────────────────────────────
TIMED_OUT=0
DEADLINE=$(( VM_START_EPOCH + TIMEOUT ))

while true; do
    remaining=$(( DEADLINE - $(date -u +%s) ))
    if [[ $remaining -le 0 ]]; then
        TIMED_OUT=1; break
    fi
    # Cap per-line timeout at 5 s so the deadline is checked frequently.
    read_limit=$(( remaining < 5 ? remaining : 5 ))
    if ! IFS= read -r -t "$read_limit" line <&3; then
        # read -t exits 1 on timeout (no complete line); >128 on signal.
        TIMED_OUT=1; break
    fi
    printf '%s\n' "$line" >> "$DMESG_FILE"
    # Stop reading as soon as the test runner signals completion.
    [[ "$line" == *TEST_DONE* ]] && break
done

exec 3>&-

VM_DURATION=$(( $(date -u +%s) - VM_START_EPOCH ))

# ── Parse, evaluate, record, and report ──────────────────────────────────────

parse_serial_output   "$DMESG_FILE"
determine_boot_status "$DMESG_FILE" 0 "$TIMED_OUT"
write_run_status      "$STATUS_FILE" "$VM_START_TIME" "$VM_DURATION"

log_run_result "$CONFIG / $ARCH (board: $BOARD_TTY)" || exit 1
