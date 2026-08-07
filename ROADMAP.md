# kernel-test — Roadmap

## Current State (2026-08-06)

- 38 VM tests across 4 arches (x86_64, i386, arm64, riscv), 9 default + 7 ns-variant config profiles
- Namespace regression suite live (290–360, C binaries × 4 arches)
- `make extended` = full + ns-full (10 configs) for Hetzner staging automation
- All testing is QEMU/KVM; no physical hardware path yet

## Goal

Run the existing test suite plus arch-specific and watchdog tests on a **VisionFive 2
(StarFive JH7110)** board connected via USB-UART dongle, with automated timeout detection,
out-of-band reset via USB relay, and tftp-based kernel delivery. Produce hardware results
that can be diffed against QEMU runs to catch QEMU vs real-silicon divergence.

---

## Implementation Phases

Each phase is a separate branch, independently testable, and merges to `main` before the
next phase begins. Dependencies are noted; parallel work is called out explicitly.

---

### Phase 1 — `refactor/common-serial-parser` ✓ DONE (branch merged to main)

**What:** Extract the serial output parser and `vm.status` writer from `lib/vm.sh` into
shared helpers in `lib/common.sh`. `lib/vm.sh` becomes a thin QEMU wrapper that calls
those helpers. No behaviour change.

**Why first:** `lib/board.sh` (Phase 5) must call the same parser to produce identical
`vm.status` output. Doing this refactor now keeps board.sh small and avoids duplicating
the parser — the most complex logic in the pipeline. Deferring it means refactoring
`vm.sh` under pressure mid-board implementation.

**Files changed:** `lib/vm.sh`, `lib/common.sh`

**How to test:**
```sh
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS="x86_64 i386"   # unchanged output
make ci-test                                                   # all Tier 2 tests pass
```

**Dependency:** none — do this first.

---

### Phase 2 — `feat/arch-tests` *(parallel with Phase 3)* ✓ DONE (branch merged to main)

**What:** Three new VM test scripts covering architecture-specific kernel behaviour:

- `370_riscv-isa.sh` — parse `/proc/cpuinfo` ISA string; verify baseline extensions
  (I, M, A, F, D, C are present); FPU availability; atomic instruction sanity via a
  compiled binary if available; skip on non-riscv arch
- `380_arm64-features.sh` — parse `/proc/cpuinfo` `Features:` line; verify NEON and LSE
  are present (both mandatory on ARMv8+); skip SVE/PAC/MTE checks if extensions absent;
  skip on non-arm64 arch
- `400_perf-events.sh` — verify `perf_event_paranoid` readable; attempt `perf_event_open`
  with `PERF_TYPE_SOFTWARE` / `PERF_COUNT_SW_TASK_CLOCK` via a small C helper binary;
  verify a non-zero count is returned; skip if `CONFIG_PERF_EVENTS=n`

**Why perf_events promoted here:** the riscv PMU subsystem is actively developed and
frequently broken across kernel versions. Software counters (`PERF_TYPE_SOFTWARE`) work
in QEMU TCG without any hardware PMU, so the test verifies the syscall path cleanly on
QEMU today and catches real-silicon regressions on the VisionFive 2 without code changes.

**Why arm64 ISA tests too:** same test pattern, same value — any future arm64 board
benefits immediately. The per-arch skip guard makes all scripts safe to inject into all
initramfs images.

**Challenge:** QEMU TCG exposes a conservative extension set by default. The ISA tests
must use the string the kernel actually reports, not assume QEMU == hardware. The value
is catching kernel regressions in extension detection, not validating instruction execution.

**How to test:**
```sh
make all NO_FETCH=1 CONFIGS=defconfig ARCHS="riscv arm64"
make ci-test   # CI test verifies skip guards, executable bit, inventory entry
```

**Dependency:** none (parallel with Phase 3).

---

### Phase 3 — `feat/watchdog-test` *(parallel with Phase 2)* ✓ DONE (branch merged to main)

**What:** `390_watchdog.sh` — verify `/dev/watchdog` node exists and is a character
device; verify `CONFIG_WATCHDOG=y` via `/proc/config.gz` if available; skip gracefully
if absent. On QEMU this exercises `CONFIG_SOFTDOG`. On the VisionFive 2 this will verify
the StarFive hardware watchdog (`CONFIG_STARFIVE_WATCHDOG`) is present and reachable.

**Note:** the watchdog test does NOT replace out-of-band reset (USB relay). The kernel
watchdog only fires if the kernel is still alive enough to kick it. The relay handles
hard hangs where the kernel is dead. These are complementary, not alternatives.

**How to test:**
```sh
# CONFIG_SOFTDOG=y is present in defconfig by default
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64
make ci-test
```

**Dependency:** none (parallel with Phase 2).

---

### Phase 4 — `feat/visionfive2-config` ✓ DONE (branch merged to main)

**What:** New config profile `vf2config` for the StarFive JH7110 SoC:

- Base: `riscv defconfig` (already includes most upstream JH7110 drivers)
- Fragment `configs/vf2config.config`: pin JH7110 SoC identity (LOCALVERSION=-vf2);
  promote JH7110 drivers from =m to =y (Ethernet/DWMAC, USB/Cadence, PCIe, CLK AON/STG/VOUT/ISP,
  PHY USB/PCIe, hardware RNG, DMA/PL08x, hardware crypto/AES); watchdog sysfs;
  disable DRM/SOUND/MEDIA/STAGING; no JH7110 RTC driver exists upstream (PMIC-managed)
- Arch overlay `configs/vf2config-riscv.config`: serial console options for VF2 UART

**Why separate from board.sh:** the config profile is independent of the boot mechanism.
Build and boot `vf2config` in QEMU today to verify it compiles and the base kernel boots
— the JH7110-specific drivers will not match any QEMU device and will not probe, which
is correct and expected.

**How to test:**
```sh
make all NO_FETCH=1 CONFIGS=vf2config ARCHS=riscv   # builds + boots in QEMU riscv
# Expected: all generic tests pass; JH7110 driver probes silently absent (no FAIL)
```

**Dependency:** none (independent of Phases 2–3, but do after Phase 1).

---

### Phase 5 — `feat/board-serial` *(in progress — branch: feat/board-serial)*

**What:** `lib/board.sh` — the hardware equivalent of `lib/vm.sh`:

- Open `$BOARD_TTY` (default `/dev/ttyUSB0`) for read+write (`exec 3<>/dev/ttyUSB0`),
  set 115200 8N1, no hardware flow control
- Line-by-line read loop with `read -t $TIMEOUT` for input-side timeout detection
- Call shared parser helpers from `lib/common.sh` (Phase 1) — identical to QEMU path
- On timeout: write `BOOT=HANG` to `vm.status`, print "manual reset required", exit 1
- `board_reset` stub: logs the event cleanly, does nothing yet (upgraded in Phase 6)
- Write fd open from the start: later U-Boot command sending requires no reopen

**CI test fixture** `tests/ci/fixtures/board/transcript-pass.txt` must cover all parser
paths the real board produces: a U-Boot banner, `BOOT_OK`, at least one `TEST PASS`,
one `TEST FAIL`, a KTAP block (`KTAP version 1` / `ok 1` / `not ok 2`), and `TEST_DONE`.
The CI test replays this through a socat pty pair and asserts the resulting `vm.status`
matches expected `BOOT=PASS`, `TESTS_PASS`, `TESTS_FAIL`, `KUNIT_PASS`, `KUNIT_FAIL`.

**How to test without hardware:**
```sh
socat PTY,link=/tmp/vf2-tx,rawer PTY,link=/tmp/vf2-rx,rawer &
cat tests/ci/fixtures/board/transcript-pass.txt > /tmp/vf2-tx &
BOARD_TTY=/tmp/vf2-rx bash lib/board.sh
# verify vm.status content
```

CI test `tests/ci/test-board-serial.sh` runs this automatically.

**Dependency:** Phase 1 (shared parser in common.sh).

---

### Phase 6 — `feat/visionfive2-board`

**What:** Full board integration with tftp-based kernel delivery:

**Kernel delivery — tftp (recommended over SD card):**
The VisionFive 2 has Ethernet (dwmac-starfive). Pre-configure U-Boot env once
(`bootdelay=3`, `bootcmd=run tftpboot`, static or DHCP IP, tftp server address).
`lib/board.sh` copies `arch/riscv/boot/Image` and `initramfs.cpio.gz` to `/srv/tftp/`
before triggering `board_reset`. Board resets, U-Boot loads kernel + initramfs via tftp,
boots automatically. No SD card writes per run. SD card holds only SPL + U-Boot
(one-time manual flash).

**Why tftp over SD card:** eliminates per-run physical media writes; host controls all
kernel content; `board_reset` → tftp load → boot is a single automated flow with no
manual steps. Requires: host runs `tftpd-hpa` or `dnsmasq --enable-tftp`; board on same
LAN segment or direct cable.

**`board_reset` implementation:**
USB relay module wired to VF2 RST button pads. Host writes to relay device
(`/dev/ttyUSB1` or `/dev/hidraw0`) to briefly close the contact, simulating a button
press. `board_reset` calls this, then resumes reading serial — the board reboots and
U-Boot loads the new kernel from tftp.

**`make board-smoke BOARD=visionfive2`:**
Quick sanity target: build `vf2config`, copy to tftp dir, trigger reset, capture serial,
write `vm.status`. Analogous to `make smoke` for QEMU. Use this during bring-up
iteration — faster feedback than a full run before reset + delivery are confirmed working.

**QEMU vs hardware diff:**
Label hardware runs distinctly: `vf2-7.2-<date>-v7.2-rc6`. After a hardware run passes,
diff it against the matching QEMU riscv run:
```sh
make diff OLD=reports/mainline-7.2-<date>-v7.2-rc6 NEW=reports/vf2-7.2-<date>-v7.2-rc6
```
`PASS→FAIL` entries identify tests that pass in QEMU TCG but fail on real JH7110 silicon
— this is the primary new signal hardware testing provides. Capture these in a
`vf2-divergence.txt` report.

**Hardware required:**
- VisionFive 2 board (StarFive JH7110)
- USB-UART dongle: GND → J29 pin 1, RX → J29 pin 2 (board TX), TX → J29 pin 3 (board RX)
- USB relay module (~€10): COM + NO wired to VF2 RST button pads; `/dev/ttyUSB1`
- Ethernet cable: host ↔ board (or shared switch); host runs tftp server
- SD card with VF2 SPL + U-Boot pre-flashed (one-time manual setup)

**How to test:**
```sh
make board-smoke BOARD=visionfive2         # first: bring-up sanity
make board BOARD=visionfive2               # full run once smoke passes
make diff OLD=<qemu-riscv-run> NEW=<vf2-run>  # find QEMU vs hardware divergence
```

**Dependency:** Phases 1, 4, 5.

---

## Dependency Order

```
Phase 1: refactor/common-serial-parser        ← do first, no deps
    │
    ├── Phase 2: feat/arch-tests              ← parallel; no dep on 1 but do after
    ├── Phase 3: feat/watchdog-test           ← parallel with 2
    ├── Phase 4: feat/visionfive2-config      ← independent; build/boot in QEMU
    │
    └── Phase 5: feat/board-serial            ← requires Phase 1
            │
            └── Phase 6: feat/visionfive2-board  ← requires Phases 1, 4, 5
```

Recommended sequence if working serially: **1 → 2 → 3 → 4 → 5 → 6**

---

## Phase 7 — LKML Submission *(nice to have, post-Phase 6)*

The `summary.mail.txt` report already contains the right content. A `make send` target
using `git send-email` or `msmtp` would close the original project goal.

Prerequisites before sending:
- At least one hardware run (VF2) included in the report alongside QEMU results
- Hardware and QEMU results for the same kernel version in the same report run
- `summary.mail.txt` updated to include the hardware section and QEMU vs VF2 divergence count
- `get_maintainer.pl` / manual To/Cc for lkml + linux-riscv mailing lists

---

## Future Tests *(post-Phase 6, QEMU-verifiable first, any order)*

| Test | What it covers | Why it matters |
|---|---|---|
| `seccomp` | `prctl(PR_SET_SECCOMP)` strict + BPF filter | Browsers, containers; regressions break Chrome |
| `io_uring` | setup, submission, completion queue basics | Heavy merge traffic per cycle; high regression signal |
| `timerfd` / `signalfd` | fd-based async primitives | Used by systemd and containers |

---

## Out of Scope

- **GitHub Actions CI with hosted runners** — too costly; Hetzner staging covers automated runs
- **Multiple board types** — `lib/board.sh` is generic; `feat/visionfive2-board` is board-specific; a second board type follows the same pattern without touching Phase 5
- **SD card per-run kernel writes** — replaced by tftp; SD card holds SPL + U-Boot only
