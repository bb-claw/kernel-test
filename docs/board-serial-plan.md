# Board Serial — Plan

Branch: `feat/board-serial`
Start date: 2026-08-07

---

## Situation

`lib/vm.sh` boots kernels in QEMU and captures serial output by telling QEMU to write its
virtual serial port to a file. Real hardware has a physical UART (`/dev/ttyUSB0`) instead.
Phase 1 already extracted the serial output parser from `vm.sh` into shared helpers in
`lib/common.sh`; `lib/board.sh` can call those same helpers and produce identical
`vm.status` output, making hardware runs drop-in comparable to QEMU runs.

---

## Problems to Solve

1. **No host-side TTY capture** — nothing opens the USB-UART dongle, reads serial lines
   with timeout detection, and calls the shared parser.
2. **No board reset stub** — Phase 6 will add a USB relay; Phase 5 needs the call site to
   exist so Phase 6 only fills in one function.
3. **No CI test** — board.sh can only be proven correct by replaying a known transcript
   through a socat pty pair and checking the resulting `vm.status`.
4. **No `make board-smoke` / `make board` targets** — no user-facing entry point.

---

## Goals

1. `lib/board.sh` reads from `$BOARD_TTY` (default `/dev/ttyUSB0`), applies 115200 8N1 via
   `stty`, reads lines with a wall-clock deadline, and produces an identical `vm.status`
   to a QEMU run.
2. `board_reset` stub exists, logs "manual action required", does nothing (Phase 6 fills it).
3. `tests/ci/test-board-serial.sh` passes without hardware by replaying fixtures through
   socat pty pairs.
4. `make board-smoke BOARD_TTY=/dev/ttyUSB0` and `make board BOARD_TTY=/dev/ttyUSB0` are
   documented and wired in the Makefile.
5. `make ci-test` and `make lint` pass.

---

## Scope

Files/components changed:
- `lib/board.sh` — new; hardware equivalent of vm.sh
- `lib/bootstrap.sh` — add serial-capture host build step
- `tests/ci/test-board-serial.sh` — new; socat-based CI test (36 assertions)
- `tests/ci/fixtures/board/transcript-pass.txt` — new; U-Boot + boot + tests + KTAP + TEST_DONE
- `tests/ci/fixtures/board/transcript-panic.txt` — new; kernel panic transcript
- `tests/ci/fixtures/board/transcript-boot-hang.txt` — new; BOOT_OK but no TEST_DONE
- `tests/programs/serial-capture/serial-capture.c` — new; host-side UART capture binary
- `tests/programs/serial-capture/Makefile` — new; host-only build (no cross-compilation)
- `Makefile` — add `board-smoke` and `board` targets, `BOARD_TTY` variable
- `ROADMAP.md` — mark Phase 5 in progress
- `memory/workflows.md` — document new board workflow variables and targets

No changes to: `lib/vm.sh`, `lib/common.sh`, `lib/initramfs.sh`, any test scripts in
`tests/custom/`, the report or diff pipeline.

---

## Non-goals

- **Wiring serial-capture.c into board.sh** — the C binary is committed and buildable in
  this phase (`make bootstrap` builds it) but `board.sh` uses the Bash `stty+read` path.
  Phase 6 upgrades `board.sh` to use it as the capture backend.
- **Actual UART communication** — board.sh reads only; no U-Boot command sending in Phase 5.
  The write fd is opened (`exec 3<>$BOARD_TTY`) so Phase 6 can send U-Boot commands without
  reopening.
- **USB relay control** — `board_reset` stub only; Phase 6 wires the relay.
- **tftp kernel delivery** — Phase 6 concern; Phase 5 assumes the board is already booting
  a pre-loaded kernel.
- **Multiple board types** — `BOARD_TTY` variable + config is board-agnostic; the board
  type (`visionfive2`) is a Phase 6 label concern.

---

## Design decisions

### Wall-clock timeout vs per-line timeout

`read -t TIMEOUT` gives a per-line timeout: it fires only when no data arrives for TIMEOUT
seconds. A boot loop (board alive but stuck, printing continuously) would never time out.
Using a wall-clock deadline (`DEADLINE=$(( $(date +%s) + TIMEOUT ))`; `remaining` shrunk
each iteration) ensures total session time is bounded regardless of board behaviour.

Per-line timeout still matters as a failsafe: `read -t remaining` where remaining is the
shrinking remainder of the wall-clock budget.

### TTY configuration (stty vs termios in C)

`stty -F $BOARD_TTY 115200 cs8 -cstopb -parenb -crtscts raw -echo` is sufficient for
host-side read-only capture. A C binary with POSIX `tcsetattr` would handle binary
garbage, break signals, and sub-millisecond timing — none of which matter for the kernel
boot transcript use case. Deferred to Phase 6 if hardware proves otherwise.

In CI (`socat PTY,rawer`), the pty is already in raw mode; `stty` on a pty is a no-op
for the baud rate (ptys are virtual) but does not error, so the same code path works.

### Write fd open at boot.sh start

`exec 3<>$BOARD_TTY` opens the TTY for both read and write from the start. The current
Phase 5 implementation only reads; the write fd is unused but present. Phase 6 will send
U-Boot commands through fd 3 without needing to reopen or reconfigure the TTY.

### CI test: socat pty pair

`socat PTY,link=TX,rawer PTY,link=RX,rawer` creates a virtual serial cable. One end
receives the fixture transcript (`cat transcript.txt > TX`); the other is `BOARD_TTY=RX`
for board.sh. The CI test does not require any USB hardware. Socat must be installed
(`make bootstrap` installs it).

### serial-capture.c vs Bash stty+read

A host-side C binary `tests/programs/serial-capture/serial-capture.c` is included in this
phase and built by `make bootstrap`. It is NOT wired into `board.sh` yet:

**Why serial-capture.c is valuable (Phase 6 upgrade):**
- `O_NOCTTY`: prevents capture process from acquiring the board TTY as its controlling terminal
- `tcflush(TCIOFLUSH)`: drops stale buffered bytes on open — critical on reconnect after a reset
- Binary-safe: captures every byte verbatim (no line-discipline mangling, no newline requirement)
- `fdatasync()` every 8 writes: protects captured data against host crash
- `VMIN=1, VTIME=1`: non-blocking check every 100ms; SIGTERM/SIGINT → clean shutdown with final sync

**Why board.sh stays Bash for Phase 5:**
- The socat pty CI test works with `read -t` but would require polling a file if serial-capture
  is used as a background process
- The Bash path is fully tested and sufficient for the Phase 5 goal (proven CI + basic hardware testing)
- Wiring serial-capture into board.sh changes the architecture (background spawn + poll loop)
  and is the natural scope of Phase 6

**Phase 6 upgrade path:** board.sh checks for `tests/programs/serial-capture/bin/serial-capture`;
if present, spawns it in background and polls `$DMESG_FILE` for TEST_DONE; otherwise uses the
Bash fallback. The CI test `run_board_replay` continues to work in both modes since serial-capture
correctly reads from a socat pty (EIO on pty close → clean exit).

### `board-smoke` vs `board` Makefile targets

`board-smoke` captures serial from a board that is already running (no build, no reset).
`board` is the full intended flow: build vf2config + copy to tftp + reset + capture + report.
For Phase 5, `board` does not trigger tftp delivery or USB relay reset — those are Phase 6.
Both targets require `BOARD_TTY` to be set to a real device on the host.

---

## Testing strategy

- **CI (no hardware)** — `tests/ci/test-board-serial.sh`: socat pty pair replays
  `transcript-pass.txt` (full pass) and `transcript-timeout.txt` (hang); asserts
  `vm.status` contents match expected values for each scenario.
- **Lint** — `shellcheck` on `lib/board.sh`; executable bit check.
- **Manual (with hardware)** — connect USB-UART to VisionFive 2, boot a vf2config kernel,
  run `BOARD_TTY=/dev/ttyUSB0 TIMEOUT=360 BUILD_DIR=build bash lib/board.sh vf2config riscv`.
- **No QEMU test needed** — board.sh does not invoke QEMU; the shared parser is already
  covered by `tests/ci/test-vm-parser.sh`.

---

## Testing commands

```sh
# 1. CI test (no hardware needed)
make ci-test
# Expected: test-board-serial.sh: N passed, 0 failed

# 2. Lint
make lint
# Expected: 0 errors, 0 warnings

# 3. Manual socat replay (without make)
socat PTY,link=/tmp/vf2-tx,rawer PTY,link=/tmp/vf2-rx,rawer &
sleep 0.3
cat tests/ci/fixtures/board/transcript-pass.txt > /tmp/vf2-tx
BUILD_DIR=/tmp/bs-test TIMEOUT=30 BOARD_TTY=/tmp/vf2-rx \
    bash lib/board.sh vf2config riscv
cat /tmp/bs-test/vf2config-riscv/vm.status
# Expected: BOOT=PASS, TESTS_PASS=2, TESTS_FAIL=1, KUNIT_PASS=1, KUNIT_FAIL=2
# (KUNIT_FAIL=2: 1 failing subtest + 1 failing suite summary line — both counted by design)
```
