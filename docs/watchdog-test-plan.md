# Watchdog Test — Plan

Branch: `feat/watchdog-test`
Start date: 2026-08-07

---

## Situation

Phase 3 of the VisionFive 2 roadmap. The watchdog subsystem has two independent paths
in Linux: the device watchdog (`/dev/watchdog` + driver) and the softlockup NMI detector
(`/proc/sys/kernel/watchdog` + `CONFIG_SOFTLOCKUP_DETECTOR`). A regression in either
path would go undetected without a targeted test. On the VisionFive 2, `CONFIG_STARFIVE_WATCHDOG`
is the relevant hardware driver; `CONFIG_SOFT_WATCHDOG` covers QEMU TCG for all arches.

---

## Problems to Solve

1. **Watchdog device untested** — no existing test exercises `/dev/watchdog`, character
   device presence, sysfs attributes, or the open+write+magic-close sequence. A silent
   regression in the watchdog core or softdog driver would be invisible.
2. **Config not boot-tested** — `CONFIG_SOFT_WATCHDOG` is not in any default config
   profile; defconfig, kunitconfig, and all ns-variant configs lack it. Test would always
   skip without config fragment additions.

---

## Goals

1. `tests/custom/390_watchdog.sh` passes on defconfig and kunitconfig for all four arches
   under QEMU, exercising: device node presence, char-device type, sysfs attributes
   (identity, timeout, nowayout, state), and magic-close write.
2. Script skips cleanly on tinyconfig, allnoconfig, and any config where the watchdog
   device is absent.
3. `tests/ci/test-watchdog-script.sh` passes under `make ci-test` — verifies structure,
   skip guard, shellcheck compliance, and exit-0 on CI host (non-root, device absent or
   unwritable).
4. `configs/defconfig.config` (new) and `configs/kunitconfig.config` (updated) enable
   `CONFIG_SOFT_WATCHDOG=y` + `CONFIG_WATCHDOG_SYSFS=y`.

---

## Scope

Files/components changed:
- `tests/custom/390_watchdog.sh` — new VM test script (slot 390, between 380 and 400)
- `configs/defconfig.config` — new fragment; auto-applied by build.sh when present
- `configs/kunitconfig.config` — append watchdog options (defconfig base needs explicit addition too)
- `tests/ci/test-watchdog-script.sh` — new Tier 2 CI test
- `memory/test-inventory.md` — add 390 row, update count + next slot
- `memory/project.md` — update test count
- `CLAUDE.md` — next slot stays 420_ (390 fills the gap between 380 and 400)

No changes to: `lib/initramfs.sh`, `lib/bootstrap.sh`, `lib/vm.sh` — no C binary needed.

---

## Non-goals

- **StarFive hardware watchdog testing** — `CONFIG_STARFIVE_WATCHDOG=y` is already in
  riscv defconfig, but the driver does not probe in QEMU. The test gracefully handles
  multiple registered watchdog devices via the sysfs enumeration path, and will exercise
  the hardware driver automatically once the VisionFive 2 board path (Phase 6) is live.
- **Watchdog timeout/reboot verification** — deliberately NOT testing the timer expiry
  (reboot). Testing the open+magic-close sequence is sufficient to verify the kernel path.
- **NOWAYOUT enforcement** — if `CONFIG_WATCHDOG_NOWAYOUT=y`, the magic-close test is
  skipped (not failed). NOWAYOUT is not set in defconfig.
- **Softlockup detector** — `CONFIG_SOFTLOCKUP_DETECTOR=n` in all tested defconfigs.
  Checked opportunistically if present; absent is not a failure.

---

## Design decisions

### Device watchdog as primary, softlockup as opportunistic

The ROADMAP listed `/proc/sys/kernel/watchdog` as the primary check. Investigation of
actual defconfig builds shows `CONFIG_SOFTLOCKUP_DETECTOR=n` for x86_64, arm64, and
riscv — the sysctl is absent. The device watchdog (`/dev/watchdog`) is the only
meaningful path and requires `CONFIG_SOFT_WATCHDOG=y` (added via config fragment).

### Config fragments rather than defconfig built-in assumption

The ROADMAP stated "CONFIG_SOFTDOG=y is present in defconfig by default." Inspection of
`build/defconfig-x86_64/.config` shows `# CONFIG_SOFT_WATCHDOG is not set`. Creating
`configs/defconfig.config` and appending to `configs/kunitconfig.config` is the correct
fix. `build.sh` already applies `configs/${CONFIG}.config` when it exists (line 218).

### sysfs enumeration and name-based correlation

All entries under `/sys/class/watchdog/watchdog*` are enumerated (not just `watchdog0`).
On VisionFive 2, both softdog and the StarFive hardware watchdog may register, and the
device that `/dev/watchdog` maps to is whichever registered first. To read the correct
nowayout before writing, the script derives the sysfs target name from the device path:
`/dev/watchdog` (misc backward-compat device) always opens the first registered watchdog,
so it maps to `watchdog0`; `/dev/watchdogN` maps to `watchdogN` directly.

Major:minor matching was considered but rejected: `/dev/watchdog` uses major 10
(MISC_MAJOR), while `/sys/class/watchdog/watchdogN/dev` reflects the watchdog core's
dynamically allocated major from `alloc_chrdev_region()` — they never match in practice.

### /proc/config.gz consistency check

When `/proc/config.gz` is available (CONFIG_IKCONFIG_PROC=y, present in defconfig/kunitconfig),
the script checks that the running kernel has CONFIG_WATCHDOG=y. If `/dev/watchdog` was found
but CONFIG_WATCHDOG=n is in the running config, the script reports FAIL — this is a
contradiction that indicates a config/boot mismatch. When the device is absent and
CONFIG_WATCHDOG=n, the result is skip (expected for tinyconfig-class builds).

### Magic-close "V" is a single shell redirect

`printf 'V' > "$WD"` opens the fd, writes "V" (sets the magic-close flag), and closes the fd
on redirect completion — all in one operation. The timer is started on open and immediately
disarmed on close. This is safe as long as NOWAYOUT=0.

### Write failure is FAIL in VM, safe in CI via WATCHDOG_DEV

Writing to `/dev/watchdog` requires root. In the VM, init runs as PID 1 (root), so a
write failure indicates a real misconfiguration and is reported as FAIL. On the CI host,
`WATCHDOG_DEV=/nonexistent` keeps WD empty (device-absent path), so the write test is
never reached — no false CI failures regardless of host permission state. Running the CI
test without the override would risk either opening the real host watchdog (root CI) or
producing a FAIL line (non-root CI), so the override is mandatory in both CI test cases.

### WATCHDOG_DEV env var for CI skip-guard testing

`390_watchdog.sh` reads `WATCHDOG_DEV` (default empty). The CI test sets
`WATCHDOG_DEV=/nonexistent` to force the device-absent skip path without depending on
the actual host watchdog state. Same pattern as `PERF_BIN` in `400_perf-events.sh`.

---

## Testing strategy

- **QEMU/defconfig x86_64, i386, arm64, riscv** — CONFIG_SOFT_WATCHDOG=y via fragment;
  `/dev/watchdog` appears; full test path: presence, char device, major:minor→sysfs match,
  attributes (identity, timeout, nowayout, state), magic-close write, /proc/config.gz check;
  all ok: lines expected.
- **QEMU/kunitconfig all arches** — same watchdog fragment appended directly; PASS.
- **QEMU/tinyconfig all arches** — no watchdog device; all device checks skip; exits 0.
- **QEMU/allnoconfig all arches** — same as tinyconfig; exits 0.
- **QEMU/randdefconfig all arches** — no watchdog fragment (configs/randdefconfig.config
  does not include watchdog options); test skips.
- **CI host** — `WATCHDOG_DEV=/nonexistent` in both CI test cases; device section skips;
  exits 0 regardless of host root status or /dev/watchdog presence.
- **`make ci-test`** — test-watchdog-script.sh: structure checks, skip-guard via env var,
  shellcheck, exit-0 on host.

---

## Testing commands

```sh
# 1. CI self-tests (Tier 2, no kernel/QEMU)
make ci-test
# Expected: all tests pass including test-watchdog-script

# 2. Smoke: defconfig x86_64 (primary path — softdog device should appear)
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64 NO_BUILD=0
# Expected: 390_watchdog PASS, ok: device /dev/watchdog present, identity='Software Watchdog'

# 3. Skip path: tinyconfig (no watchdog device)
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64 NO_BUILD=1
# Expected: 390_watchdog PASS (exits 0), all lines are skip:

# 4. Full smoke across all arches
make smoke NO_FETCH=1
make all NO_FETCH=1 CONFIGS=defconfig
```
