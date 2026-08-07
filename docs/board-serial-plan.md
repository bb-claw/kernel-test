# Board Serial — Plan

Branch: `feat/board-serial`
Start date: 2026-08-07
Status: **complete**

---

## Situation

`lib/vm.sh` boots kernels in QEMU and captures serial output by telling QEMU to write its
virtual serial port to a file. Real hardware has a physical UART (`/dev/ttyUSB0`) instead.
Phase 1 already extracted the serial output parser from `vm.sh` into shared helpers in
`lib/common.sh`; `lib/board.sh` calls those same helpers and produces identical
`vm.status` output, making hardware runs drop-in comparable to QEMU runs.

---

## Problems Solved

1. **No host-side TTY capture** — `lib/board.sh` opens `$BOARD_TTY`, captures serial
   output with a wall-clock deadline, calls shared parser helpers.
2. **No board reset stub** — `board_reset()` stub exists; Phase 6 fills in the USB relay.
3. **No CI test** — `tests/ci/test-board-serial.sh` replays 4 fixtures through socat pty
   pairs and verifies the resulting `vm.status` without hardware.
4. **No `make board-smoke` / `make board` targets** — both wired; `BOARD_CONFIG` and
   `BOARD_ARCH` parameterize the target (default: `vf2config` / `riscv`).
5. **KTAP timestamps required** — parser regex made optional; works with and without
   `CONFIG_PRINTK_TIME=y`.

---

## Goals

All met:

1. `lib/board.sh` reads from `$BOARD_TTY`, produces identical `vm.status` to a QEMU run.
2. `board_reset` stub logs "manual action required", does nothing (Phase 6 fills it).
3. `tests/ci/test-board-serial.sh` — 42 assertions across 13 test groups, all pass.
4. `make board-smoke` and `make board BOARD_TTY=/dev/ttyUSB0` wired in Makefile.
5. `make ci-test` and `make lint` pass.

---

## Scope

Files changed:

| File | Change |
|---|---|
| `lib/board.sh` | New; prefers serial-capture C binary, Bash read fallback |
| `lib/bootstrap.sh` | Add serial-capture host build step (warn-only on fail) |
| `lib/common.sh` | KTAP timestamp regex made optional |
| `Makefile` | `board-smoke`, `board`, `BOARD_CONFIG`, `BOARD_ARCH`, `TFTP_DIR` |
| `tests/ci/test-board-serial.sh` | New; 42 assertions, 5 transcript scenarios |
| `tests/ci/test-vm-parser.sh` | Board transcript parse-count assertions added |
| `tests/ci/fixtures/board/transcript-pass.txt` | New; U-Boot + full pass + KTAP + TEST_DONE |
| `tests/ci/fixtures/board/transcript-panic.txt` | New; kernel panic |
| `tests/ci/fixtures/board/transcript-boot-hang.txt` | New; BOOT_OK but no TEST_DONE |
| `tests/ci/fixtures/board/transcript-uboot-hang.txt` | New; U-Boot TFTP error, no kernel |
| `tests/ci/fixtures/parser/transcript-ktap-notimestamp.txt` | New; KTAP without timestamps |
| `tests/programs/serial-capture/serial-capture.c` | New; host-side UART capture binary |
| `tests/programs/serial-capture/Makefile` | New; host-only build |
| `tests/programs/serial-capture/.gitignore` | New |
| `memory/workflows.md` | New board variables and targets |
| `ROADMAP.md` | Phase 5 marked complete; Phase 6 marked next milestone |

---

## Design Decisions

### C backend: serial-capture vs Bash stty+read

`tests/programs/serial-capture/serial-capture.c` is committed and built by `make bootstrap`.
`lib/board.sh` prefers it when present:

- `O_NOCTTY`: prevents capture from acquiring the UART as its controlling terminal
- `tcflush(TCIOFLUSH)`: drops stale buffered bytes on open — critical after a board reset
- Binary-safe: captures every byte verbatim (no line-discipline mangling)
- `fdatasync()` every 8 writes: protects data against host crash
- `VMIN=0, VTIME=1`: read() returns every 100ms even with no data, so SIGTERM reliably
  interrupts the loop (SA_RESTART with VMIN=1 caused board.sh's `wait` to hang forever)

Bash `stty+read` fallback is used when the binary is absent; `SERIAL_CAPTURE` env var can
force the Bash path in CI.

### Poll loop in board.sh (C backend)

C backend is spawned in background; board.sh polls `$DMESG_FILE` every 0.5s for `TEST_DONE`.
Wall-clock deadline (`DEADLINE=$(( epoch + TIMEOUT ))`) bounds total session time regardless
of board behaviour (a boot loop printing continuously would not cause per-line timeout).

### VMIN=0 vs VMIN=1 — SA_RESTART interaction

Linux's `signal()` sets `SA_RESTART`. With `VMIN=1`, a blocking `read()` waiting for the
first byte is automatically restarted after SIGTERM — `running=0` is never checked.
`VMIN=0, VTIME=1` causes `read()` to return every 100ms even with no data, so the
`while(running)` check fires within 100ms of SIGTERM delivery.

### socat pty pair in CI

`socat PTY,link=TX,rawer PTY,link=RX,rawer` creates a virtual serial cable. The CI test:
1. starts `board.sh` in background (`BOARD_TTY=RX`)
2. polls for `dmesg.txt` to appear (= serial-capture has opened the pty; up to 2s)
3. opens `exec 4>TX` (keeps TX slave open so socat doesn't exit on EOF)
4. writes fixture via `cat fixture >&4`
5. `wait "$board_pid"`; closes TX fd

The TX-open step (3) is critical: if TX closes before `board.sh` finishes draining the
buffer, socat exits and serial-capture gets EIO.

### BOARD_CONFIG / BOARD_ARCH parameterisation

`make board` and `make board-smoke` default to `vf2config riscv` but accept any config/arch.
The tftp copy uses `find arch/ -name Image -o -name bzImage` so it works without
arch-specific Makefile conditionals.

### Test organisation

- `test-vm-parser.sh` — unit-tests `parse_serial_output` directly (counts, parse paths)
- `test-board-serial.sh` — integration-tests the full socat → board.sh → vm.status pipeline
  (file existence, BOOT=PASS/FAIL, FAILED_TESTS, timing, Bash fallback path)

---

## Testing Strategy

- **CI (no hardware)** — `make ci-test` runs `tests/ci/test-board-serial.sh`;
  42 assertions, 5 fixtures (pass, panic, mid-test hang, U-Boot hang, Bash fallback).
- **Lint** — `shellcheck` on `lib/board.sh`; context sizes; inventory coverage.
- **Manual (with hardware)** — connect USB-UART to VisionFive 2, boot a vf2config kernel:
  ```sh
  make board BOARD_TTY=/dev/ttyUSB0
  ```
- **Parser isolation** — `test-vm-parser.sh` covers KTAP counts (with/without timestamps).

---

## Testing Commands

```sh
# CI (no hardware needed)
make ci-test    # Expected: test-board-serial.sh: 42 passed, 0 failed

# Lint
make lint       # Expected: all checks passed

# Manual socat replay
socat PTY,link=/tmp/vf2-tx,rawer PTY,link=/tmp/vf2-rx,rawer &
SERIAL_CAPTURE=/nonexistent \                 # force Bash path; remove to use C backend
BUILD_DIR=/tmp/bs-test TIMEOUT=30 BOARD_TTY=/tmp/vf2-rx \
    bash lib/board.sh vf2config riscv &
cat tests/ci/fixtures/board/transcript-pass.txt > /tmp/vf2-tx
wait; cat /tmp/bs-test/vf2config-riscv/vm.status
# Expected: BOOT=PASS, TESTS_PASS=2, TESTS_FAIL=1, KUNIT_PASS=1, KUNIT_FAIL=2
```
