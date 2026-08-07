# VisionFive 2 Config Profile — Plan

Branch: `feat/visionfive2-config`
Start date: 2026-08-07

---

## Situation

Phase 4 of the VisionFive 2 roadmap. The config profile for the StarFive JH7110 SoC must
exist before Phase 5 (board serial) and Phase 6 (full board integration). Building and
booting `vf2config` in QEMU riscv today validates the config compiles cleanly, that the
standard test suite passes unmodified, and that no JH7110 driver silently breaks the boot.
JH7110-specific drivers (Ethernet, USB, GPIO) will not probe in QEMU — their absence is
expected and must not produce test failures.

---

## Problems to Solve

1. **No VF2-targeted config profile** — the standard `defconfig` and `tinyconfig` profiles
   do not pin VF2 identity (`CONFIG_LOCALVERSION="-vf2"`), do not promote JH7110 modules
   to built-in, and do not disable heavy subsystems that are irrelevant for VF2 work.
2. **JH7110 drivers are `=m` in riscv defconfig** — the initramfs environment has no module
   loader; Ethernet (DWMAC_STARFIVE) and USB (USB_CDNS3_STARFIVE) must be `=y` for Phase 6
   tftp boot to work without additional infrastructure.
3. **`vf2config` is not a kernel make target** — build.sh dispatches `kmake "$EFFECTIVE_CONFIG"`,
   which fails for `vf2config`. A special case in build.sh is required, analogous to
   `kunitconfig` (also not a kernel make target, also uses defconfig as base).

---

## Goals

1. `make all NO_FETCH=1 CONFIGS=vf2config ARCHS=riscv` passes — builds kernel and boots in
   QEMU riscv; 43/43 tests pass; uname reports `-vf2` suffix.
2. `make all NO_FETCH=1 CONFIGS=vf2config ARCHS=x86_64` fails with a clear diagnostic
   message ("vf2config is riscv-only") — not a silent wrong-arch build.
3. `tests/ci/test-vf2config.sh` passes under `make ci-test` — verifies both config
   fragments exist, required options are present, and build.sh has the arch guard.
4. `configs/vf2config.config` is forward-compatible: the same fragment works for Phase 6
   hardware without modification.

---

## Scope

Files changed:
- `configs/vf2config.config` — new config profile fragment
- `configs/vf2config-riscv.config` — new riscv arch overlay (pattern consistency)
- `lib/build.sh` — add vf2config dispatch case + riscv arch guard
- `tests/ci/test-vf2config.sh` — new Tier 2 CI test
- `Makefile` — add `make vf2` convenience target + help text
- `memory/config-profiles.md` — add vf2config row
- `memory/project.md` — update config count

No changes to: test scripts, initramfs.sh, bootstrap.sh — vf2config uses the same
test suite as all other profiles.

---

## Non-goals

- **Testing JH7110 hardware-specific behaviour in QEMU** — JH7110 drivers are present in
  the kernel image but do not probe in QEMU (no matching DT nodes). This is expected and
  correct. The VF2-specific test coverage comes in Phase 6.
- **Module loading in the initramfs** — initramfs has no `modprobe`; all needed drivers
  must be built-in. The fragment forces `=y` for key JH7110 subsystems.
- **U-Boot integration** — Phase 6. Phase 4 just validates the kernel config compiles.

---

## Design decisions

### riscv-only enforcement in build.sh

`vf2config` is a JH7110-specific profile; building it for x86_64 or arm64 would produce a
kernel that has no semantic relationship to the VF2 board. The build.sh case checks
`$ARCH != riscv` and exits immediately with STATUS=FAIL and a clear message, matching the
same pattern used by `localconfig` (`$ARCH != x86_64`).

### defconfig as base, not a fresh riscv defconfig from scratch

`riscv defconfig` already enables most JH7110 drivers (`SOC_STARFIVE=y`, `MMC_DW_STARFIVE=y`,
`PINCTRL_STARFIVE_JH7110*=y`, `RESET_STARFIVE_JH7110=y`, `CLK_STARFIVE_JH7110_SYS=y`,
`STARFIVE_WATCHDOG=y`, `SERIAL_8250_DW=y`). Using it as the base avoids re-specifying
dozens of options that upstream already maintains. The fragment only adds what defconfig
does not provide: LOCALVERSION, sysfs watchdog, and the =m→=y promotions.

### Promote `=m` JH7110 drivers to `=y`

riscv defconfig sets `DWMAC_STARFIVE=m`, `USB_CDNS3_STARFIVE=m`, `CLK_STARFIVE_JH7110_AON=m`,
`CLK_STARFIVE_JH7110_STG=m`, `PHY_STARFIVE_JH7110_USB=m`, `STMMAC_ETH=m`,
`STMMAC_PLATFORM=m`. In QEMU these options have no visible effect (no DT nodes match).
On the real VF2 board in Phase 6, Ethernet and USB must be built-in for tftp boot —
promoting now makes the fragment forward-compatible without a Phase 6 change.

### Dual watchdog on real VF2: softdog + starfive watchdog

On the real VF2 board with this config, two watchdog devices register:
`watchdog0` (softdog, from CONFIG_SOFT_WATCHDOG=y) and `watchdog1` (starfive hardware
watchdog, from CONFIG_STARFIVE_WATCHDOG=y already in riscv defconfig). The `/dev/watchdog`
misc device opens the first registered (`watchdog0`), and `/dev/watchdog0`/`watchdog1`
map directly.

`390_watchdog.sh` handles this via sysfs enumeration: it iterates all
`/sys/class/watchdog/watchdog*` entries, reading identity/timeout/state for each, and
uses name-based correlation (`/dev/watchdog` → `watchdog0`) to select the correct
`nowayout` value before the magic-close write. Having two entries is explicitly exercised
by this design and is correct behavior.

### CONFIG_SOFT_WATCHDOG=y for QEMU coverage

`CONFIG_STARFIVE_WATCHDOG=y` is already in riscv defconfig, but it does not probe in QEMU
(no JH7110 DT node). Adding `CONFIG_SOFT_WATCHDOG=y` ensures `390_watchdog.sh` exercises
the full watchdog path in QEMU. On real hardware, both softdog and starfive watchdog will
register; `390_watchdog.sh` enumerates all sysfs entries correctly.

### Heavy subsystems disabled

`CONFIG_DRM=n`, `CONFIG_SOUND=n`, `CONFIG_MEDIA_SUPPORT=n`, `CONFIG_STAGING=n` are
disabled. These add significant build time and module compilation without contributing
to any test in the suite. The riscv defconfig builds them as modules (`=m`); with
`MODULES=y` retained, `olddefconfig` sets them to `=n` when overridden in the fragment.

### `MODULES=y` retained

Setting `MODULES=n` would force `olddefconfig` to disable every `=m` option not
explicitly overridden, requiring the fragment to enumerate all of riscv defconfig's
modules. With `MODULES=y`, only the subset we care about (JH7110 specific) needs
explicit `=y`; everything else stays as defconfig sets it.

### `configs/vf2config-riscv.config` exists even though riscv defconfig already has serial/FPU

Pattern consistency: every bootable profile that supports riscv has a `*-riscv.config`
overlay. The file repeats the 8250+OF_PLATFORM+FPU options idempotently (no harm from
setting `=y` when already `=y` through olddefconfig).

---

## Testing strategy

- **QEMU/vf2config riscv** — JH7110-specific drivers present but not probing; softdog
  provides `/dev/watchdog`; `390_watchdog.sh` sees softdog (SOFT_WATCHDOG=y) and
  starfive watchdog (not probed in QEMU → absent from sysfs); 43/43 tests pass.
- **`ARCHS=x86_64` guard** — `make all NO_FETCH=1 CONFIGS=vf2config ARCHS=x86_64` exits
  with STATUS=FAIL and "vf2config is riscv-only" message; no kernel build attempted.
- **`make ci-test`** — `test-vf2config.sh` verifies both config files, option presence,
  build.sh guard text; exits 0.

---

## Testing commands

```sh
# 1. CI self-tests (Tier 2, no kernel/QEMU)
make ci-test
# Expected: all tests pass including test-vf2config

# 2. Primary: build and boot in QEMU riscv
make all NO_FETCH=1 CONFIGS=vf2config ARCHS=riscv
# Expected: PASS 43/43, uname shows -vf2 suffix in dmesg

# 3. Arch guard smoke test (should fail cleanly with a clear error message)
make build NO_FETCH=1 CONFIGS=vf2config ARCHS=x86_64 2>&1 | grep ERROR
# Expected: ERROR vf2config is riscv-only (StarFive JH7110 SoC) — use ARCHS=riscv

# 4. Convenience target
make vf2 NO_FETCH=1
# Equivalent to step 2
```
