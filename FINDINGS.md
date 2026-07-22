# Findings & Improvement Tracker

Issues, learnings, and improvement suggestions discovered while running the kernel-test harness.
Each finding has a status: `[ ]` open, `[x]` resolved, `[-]` won't fix, `[~]` reconsider later.

---

## 2026-07-11 — Initial Run: KUnit, Stable Kernels, and Install

### High — Build & Pipeline Correctness

- [x] **kunitconfig x86_64 build times out at 600 s** ✅ resolved 2026-07-11
  `defconfig + KUnit` on x86_64 takes ~10–12 min on a 16-core machine. The previous
  `BUILD_TIMEOUT` default of 600 s caused the kunitconfig x86_64 build to exit with
  `STATUS=TIMEOUT` while the i386 build (smaller instruction set, less work) succeeded.

  **Root cause:** `BUILD_TIMEOUT` was sized for `tinyconfig`/`allnoconfig`, not
  `defconfig`-based configs. kunitconfig uses `defconfig` as its base.

  **Fix:** Raised `BUILD_TIMEOUT` default to 1200 s (20 min) in the Makefile. The previous
  value is preserved via `BUILD_TIMEOUT=600` on the command line for scoped runs.
  Added note in `make help` that defconfig/kunitconfig x86_64 needs ~10–12 min.

- [x] **`make build test report` stops on first build failure** ✅ resolved 2026-07-11
  Chaining `make build initramfs test report` individually causes Make to stop at the first
  failing target. When one build fails, `make test` never runs and the report is never written
  — so there is no artifact to inspect after a partial build failure.

  **Fix:** `make all` now runs `report` in all cases (existing behaviour was correct for `all`,
  but the documentation and examples did not make this clear). Added the recommended invocation
  pattern — `make all NO_FETCH=1 ...` — prominently to `make help`, README, and CLAUDE.md.
  Added a second fix: the `make test` loop now reads `build.status` before each config and
  prints `SKIP (build TIMEOUT)` or `SKIP (build FAIL)` instead of blindly running `vm.sh`.
  Partial build failures no longer block testing of the configs that did build.

- [x] **`make install` uses wrong kernel tree when STABLE_RELEASE is not re-specified** ✅ resolved 2026-07-11
  After building with `STABLE_RELEASE=7.1`, running `make install CONFIGS=localconfig ARCHS=x86_64`
  (without `STABLE_RELEASE=7.1`) caused `KERNEL_TREE` to default back to `../linux` (mainline).
  `make modules` then ran the mainline tree against the 7.1.3 build directory, triggering an
  interactive `make menuconfig` prompt and hanging.

  **Root cause:** `KERNEL_TREE` is a Makefile variable, not persisted anywhere between invocations.
  `STABLE_RELEASE` must be passed every time to redirect it.

  **Fix:** `lib/build.sh` now writes `KERNEL_TREE=<absolute-path>` into every `build.status`
  write (PASS, FAIL, TIMEOUT, and all early config-fail paths). `lib/install.sh` reads it back
  and overrides the environment variable before running `make modules`. `make install` now always
  uses the correct tree regardless of whether `STABLE_RELEASE` is re-specified on the command line.

- [x] **Build output does not show which kernel tree/tag/commit is being compiled** ✅ resolved 2026-07-11
  When running a build it was unclear which kernel version was actually being compiled — especially
  when switching between mainline and stable trees. The `[build]` header only showed the config
  profile and arch.

  **Fix:** `lib/build.sh` now prints the kernel tag, short commit hash, and remote URL at the
  start of every build:
  ```
  [info] Kernel: v7.1.3 (a1b2c3d) — https://git.kernel.org/.../linux-stable.git
  [info] Tree:   /home/benni/git/linux-stable
  ```
  This is visible in both live build output and the build log copied to the report directory.

---

### Medium — Installation & Boot Issues

- [x] **`make install` fails with mkinitcpio nvidia module errors** ✅ resolved 2026-07-11
  Running `mkinitcpio -p localconfig` failed because the system `/etc/mkinitcpio.conf` has
  `MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)`. These DKMS modules are not present
  under `/lib/modules/<kver>/` for a source-built kernel — only in-tree modules are installed.

  **Fix:** `lib/install.sh` now writes a per-kernel mkinitcpio conf derived from the system
  default with `MODULES=()` cleared (`sed 's/^MODULES=.*/MODULES=()/'`), stored at
  `/etc/mkinitcpio.d/$CONFIG.conf`. The preset references this conf via `ALL_config=`.
  System hooks (autodetect, modconf, block, filesystems, etc.) are preserved — only the
  explicit MODULES override is removed. The `autodetect` hook selects the correct in-tree
  modules automatically.

  Removal instructions (added to `install.sh` summary output) now include the `.conf` file:
  ```
  sudo rm /etc/mkinitcpio.d/$CONFIG.preset /etc/mkinitcpio.d/$CONFIG.conf
  ```

- [x] **GRUB simple entry changed to the localconfig kernel after install** ✅ resolved 2026-07-11
  After `make install`, GRUB's simple top-level "Manjaro Linux" entry pointed to the source-built
  kernel instead of the distro kernel. Cause: GRUB sorts kernels alphabetically and picks the first
  one for the simple entry. `vmlinuz-localconfig-x86_64` sorts before `vmlinuz-6.15-…` (distro).

  **Symptom:** Next reboot would have booted the source-built kernel silently.

  **Fix (workaround):** `sudo grub-set-default '<Advanced submenu entry ID>'` was used to pin
  the distro kernel as the saved default before rebooting. `lib/install.sh` now warns about
  this explicitly in its post-install summary:
  ```
  NOTE: if 'vmlinuz-localconfig-x86_64' sorts before your distro kernel, it becomes
        the simple 'Manjaro Linux' entry and will boot by default.
        To pin your previous kernel: sudo grub-set-default '<Advanced submenu entry ID>'
  ```

  **Confirmed safe:** `sudo grub-editenv list` showed `saved_entry=gnulinux-7.1.3…` before reboot.

- [x] **7.2-rc2: no Magic SysRq — could not reisub on hang** ✅ resolved 2026-07-11
  When the 7.2-rc2 kernel hung (CIFS socket errors, 163 callbacks suppressed), `Alt+SysRq+B`
  was unavailable. The localconfig build did not have `CONFIG_MAGIC_SYSRQ=y`, so there was no
  way to trigger a safe reboot without a hard reset.

  **Fix:** Added to `configs/localconfig.config`:
  ```
  CONFIG_MAGIC_SYSRQ=y
  CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=1
  ```
  `MAGIC_SYSRQ_DEFAULT_ENABLE=1` enables all SysRq keys by default (equivalent to
  `/proc/sys/kernel/sysrq` = 1) without requiring a post-boot sysctl.

---

### Low — Reporting & Observability

- [x] **Build logs not included in report for non-build-only configs** ✅ resolved 2026-07-11
  `lib/report.sh` previously only copied `build.log` for `allmodconfig` and `randconfig` (the
  build-only configs). For bootable configs (defconfig, tinyconfig, etc.), the build log was
  not available in the report directory — warnings on passing builds were invisible.

  **Fix:** `lib/report.sh` now copies `build.log` for every config, writing
  `build-<config>-<arch>.log` into the report directory. Warnings on passing builds are now
  inspectable without digging into the `build/` directory.

---

## 2026-07-11 — Stable Kernel (7.1.x) Build Issues

### High — Cross-tree Build Artifacts

- [x] **Stale `ucs_width_table.h` causes 7.1.3 build failure after mainline build** ✅ resolved 2026-07-11
  After building a mainline kernel (7.2-rc2), switching to stable 7.1.3 and running
  `make build STABLE_RELEASE=7.1 CONFIGS=localconfig` failed:

  ```
  drivers/tty/vt/ucs.c:24:10: fatal error: ucs_width_table.h: No such file or directory
  ```
  Then after an `mrproper` of the source tree, the error changed to:
  ```
  drivers/tty/vt/ucs.c:28:2: error: #error Unicode 16+ table required
  ```

  **Root cause:** `ucs_width_table.h` is a generated file. Mainline (post-7.2-rc2) generates
  a Unicode 16.0 version of this header via 10 commits reworking `drivers/tty/vt/ucs.c`.
  The build artifact from the mainline build remained in `build/localconfig-x86_64/` and was
  picked up by the 7.1.3 build. The format is incompatible: 7.1.3's `ucs.c` expects the old
  shipped header (`ucs_width_table.h_shipped`), but found the mainline-generated Unicode 16.0 version.

  **Fix:** Remove the build directory before switching kernel trees:
  ```sh
  rm -rf build/localconfig-x86_64/
  ```
  Added a prominent note to `make help`, README.md, CLAUDE.md, and DESIGN.md:
  > Run `make clean` when switching between kernel trees (mainline ↔ stable). Generated
  > headers in `build/` are tied to the tree they were built from.

- [x] **Dirty linux-stable source tree blocks build** ✅ resolved 2026-07-11
  `lib/build.sh` detected uncommitted files in `~/git/linux-stable`: `include/generated/autoconf.h`
  and various kconfig `.o` files. These were left over from a prior manual build in the source tree.

  **Fix:** `make -C ~/git/linux-stable mrproper` cleans all generated files from the kernel
  source tree. Note: `mrproper` cleans the kernel's own generated files — it does not touch
  `build/` (the harness out-of-tree directory).

  **Distinction:**
  - `make clean` in kernel-test → removes `build/` and `cache/` (harness output)
  - `make -C $KERNEL_TREE mrproper` → removes generated files from the kernel source tree itself

- [x] **GCC 16 vs stable 7.1.x: initially misdiagnosed as compiler incompatibility** ✅ resolved 2026-07-11
  The `ucs_width_table.h` error was first attributed to GCC 16 incompatibility with 7.1.x.
  Testing with `GCC=gcc-15` produced the same error. The actual root cause was the stale build
  artifact (see above).

  **Outcome:** `GCC=gcc-15` was added as a supported override (`GCC ?= gcc` in Makefile,
  `CC="ccache $GCC"` in `lib/build.sh`). This is useful for stable kernels that have genuine
  GCC version incompatibilities, and matches the common stable-tree workflow where the kernel
  may have been developed against an older compiler.

  **Note for LKML:** The `drivers/tty/vt/ucs.c` Unicode 16.0 rework in mainline (10+ commits)
  has not been backported to stable 7.1.x. Attempting to build 7.1.x against mainline-generated
  headers fails with `#error Unicode 16+ table required`. This is expected behaviour (out-of-tree
  headers), not a kernel bug.

---

## 2026-07-11 — 7.2-rc2 Boot Observations

### Low — Boot Anomalies (not blocking)

- [x] **7.2-rc2 localconfig: CIFS VFS socket errors in dmesg** ✅ confirmed non-issue 2026-07-12
  dmesg on the booted 7.2-rc2 localconfig kernel showed:
  ```
  CIFS: VFS: Error connecting to socket. Aborting operation.
  CIFS: VFS: cifs_mount failed w/return code = -111
  ```
  These appear during boot when Samba/CIFS mounts configured in `/etc/fstab` are attempted
  before the network is fully up. Not a kernel regression — this is a race between the mount
  attempt and NetworkManager completing connection setup.

  **Confirmed:** Full hardware verification run on 7.2-rc2 passed (19/19 tests, all hardware
  present and functional). Kernel is working correctly. CIFS errors are a fstab/network timing
  issue, not a kernel bug. Fix if desired: add `_netdev,x-systemd.automount` to the fstab
  options for the CIFS mounts.

- [x] **7.2-rc2 localconfig: "163 callbacks suppressed" in dmesg** ✅ confirmed non-issue 2026-07-12
  dmesg showed:
  ```
  callbacks 163 suppressed
  ```
  This is the kernel's `net_ratelimit()` suppression message for the CIFS burst above — not
  an independent issue. Confirmed: does not recur without CIFS errors. No LKML report needed.

---

## 2026-07-11 — KUnit Integration

### Resolved — Feature Addition

- [x] **KUnit test results not tracked or reported** ✅ resolved 2026-07-11
  `kunitconfig` was added to the harness but KUnit KTAP output (emitted to serial console
  during boot via `do_initcalls`) was not parsed or surfaced in the report.

  **Fix — build.sh:** `kunitconfig` is now special-cased: uses `defconfig` as the base (it is
  not a kernel make target), then applies `configs/kunitconfig.config` (CONFIG_KUNIT + core
  test suites). Treated as bootable (not build-only).

  **Fix — vm.sh:** After boot capture, detects KTAP output (`KTAP version` or `# Subtest:`
  in dmesg), then counts indented `ok`/`not ok` lines (4+ spaces after timestamp). Non-indented
  suite summary lines are excluded to avoid double-counting. Results stored as `KUNIT_PASS` and
  `KUNIT_FAIL` in `vm.status`.

  **Fix — report.sh:** Reads `KUNIT_PASS`/`KUNIT_FAIL` from `vm.status`. Sets `OVERALL=FAIL`
  if `KUNIT_FAIL > 0`. Tests column shows `kunit:N/N` for kunitconfig builds, plus `sh:N/N`
  if shell tests also ran.

  **Note on design:** KUnit tests run during kernel boot (`do_initcalls`) — before `/init` is
  reached. No special initramfs changes are needed. Shell tests from the initramfs also run as
  normal alongside KUnit.

  **Config fragment** (`configs/kunitconfig.config`):
  - `CONFIG_KUNIT=y` + `CONFIG_KUNIT_DEBUGFS=y`
  - lib/ data-structure tests: list, hash, string, printf, rbtree, overflow
  - mm/ SLUB: `CONFIG_SLUB_DEBUG=y` + `CONFIG_SLUB_KUNIT_TEST=y`

---

## 2026-07-11 — 7.1.3 localconfig Second Boot

### High — Boot Failure

- [x] **7.1.3 localconfig: `failed to validate module [snd] BTF: -22` causes boot degradation** ✅ resolved 2026-07-11
  After installing the 7.1.3 localconfig kernel, boot dropped into emergency mode. The console
  showed repeated BTF validation failures:
  ```
  BPF: [148026] FUNC 59A_suspend
  BPF: type_id=40426
  BPF: Invalid name
  failed to validate module [snd] BTF: -22
  ```
  `-22` = `-EINVAL`. The kernel's in-kernel BPF module loader is rejecting BTF (BPF Type Format)
  metadata embedded in the `snd` module at load time.

  **Root cause:** pahole v1.31 (the BTF-generation tool) encodes modules with
  `--btf_features=layout` (added for pahole ≥1.31 in the kernel's `scripts/Makefile.btf`).
  The `layout` encoding produces BTF data that the 7.1.3 stable kernel's BPF module verifier
  does not recognise, causing it to reject the module with `-EINVAL`. The Manjaro 7.0.x kernel
  is patched to handle this; vanilla stable 7.1.3 is not. This is a toolchain/kernel-age
  mismatch — newer pahole, older stable kernel.

  **Fix:** Added to `configs/localconfig.config`:
  ```
  CONFIG_DEBUG_INFO_NONE=y
  CONFIG_DEBUG_INFO_BTF=n
  CONFIG_DEBUG_INFO_BTF_MODULES=n
  ```
  `DEBUG_INFO_NONE` disables DWARF debug symbol generation entirely — the most expensive
  part of a kernel build. With no debug info, pahole has nothing to process and the BTF
  validation error cannot occur. BPF CO-RE (Compile Once, Run Everywhere) is unavailable
  on this kernel, but the kernel is otherwise fully functional. Kernel-internal BPF (used
  by systemd, network tools) is unaffected — BTF is only needed for CO-RE portability.
  Removing DWARF5 also cuts build time significantly (debug info compilation is the
  second-most expensive step after compiling the C source itself).

  **Emergency mode root cause:** Unknown without `journalctl -b -p err`. The `snd` BTF
  failure alone should not trigger emergency mode — a kernel module failing to load doesn't
  halt boot. The actual trigger is a failed mount or systemd unit that requires investigation
  from the emergency shell:
  ```sh
  journalctl -xb --no-pager | grep -E 'Failed|Dependency|error' | head -30
  systemctl --failed
  ```

### Medium — Emergency Recovery

- [x] **Magic SysRq (REISUB) disabled at boot despite CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=1** ✅ resolved 2026-07-11
  Even after adding `CONFIG_MAGIC_SYSRQ=y` and `CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=1` to
  `configs/localconfig.config`, REISUB still did not work. The console showed:
  ```
  sysrq: This sysrq operation is disabled
  ```

  **Root cause:** `/usr/lib/sysctl.d/50-default.conf` (installed by systemd) sets:
  ```
  kernel.sysrq = 16
  ```
  `systemd-sysctl.service` applies this early in boot and overrides the kernel compile-time
  default. Value 16 is bitmask bit 4 (sync only). The required operations for REISUB are:
  - R (unraw) → bit 2 = not in 16
  - E/I (signal processes) → bit 6 = not in 16
  - S (sync) → bit 4 = ✓ in 16
  - U (remount ro) → bit 5 = not in 16
  - B (reboot) → bit 7 = not in 16

  The `CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE` option sets the kernel's own default, but sysctl
  files take effect after the kernel starts and always win.

  **Fix:** `lib/install.sh` now writes `/etc/sysctl.d/99-sysrq.conf` (priority 99 > systemd's
  50) as part of the install step:
  ```
  kernel.sysrq = 1
  ```
  Files in `/etc/sysctl.d/` override `/usr/lib/sysctl.d/` by naming convention (etc wins over
  usr). This applies on every boot, for any kernel, without any per-kernel configuration.

  **Manual workaround** when the file isn't installed yet (from any shell):
  ```sh
  echo 1 | sudo tee /proc/sys/kernel/sysrq
  ```
  Then REISUB works immediately for the current boot.

---

## 2026-07-18 — Kernel Bugs Found by Random-Config Testing

### High — Build Failure

- [x] **PINCTRL_MICROCHIP_SGPIO missing `select REGMAP_MMIO` — build fails without regmap** ✅ fix confirmed 2026-07-18
  Kernel: v7.2-rc2 and v7.2-rc3. Arch: arm64 (affects all arches). Found by rand500config sampling.

  `pinctrl-microchip-sgpio.c` includes `<linux/mfd/ocelot.h>` which calls
  `ocelot_regmap_from_resource()` → `devm_regmap_init_mmio()`. Both the function and
  `struct regmap_config` are guarded by `#ifdef CONFIG_REGMAP` in `<linux/regmap.h>`, and
  `CONFIG_REGMAP` is only auto-selected when `CONFIG_REGMAP_MMIO` is selected. The Kconfig
  entry for `PINCTRL_MICROCHIP_SGPIO` is missing `select REGMAP_MMIO`, so a random config
  that enables the driver without independently enabling `REGMAP_MMIO` fails to build.

  **Build errors:**
  ```
  include/linux/mfd/ocelot.h:34: error: implicit declaration of function 'devm_regmap_init_mmio'
  drivers/pinctrl/pinctrl-microchip-sgpio.c:910: error: variable 'regmap_config' has initializer but incomplete type
  drivers/pinctrl/pinctrl-microchip-sgpio.c:911: error: 'struct regmap_config' has no member named 'reg_bits'
  ```

  **Note:** `# CONFIG_REGMAP_BUILD is not set` in the trigger config is a red herring —
  `REGMAP_BUILD` exists only for KUnit testing and has no bearing on the actual regmap library.
  A config with both `PINCTRL_MICROCHIP_SGPIO=y` and `REGMAP_MMIO=y` (selected by something
  else) builds successfully. The bug only triggers when `REGMAP_MMIO` is absent.

  **Comparison:** `PINCTRL_OCELOT` uses the same `ocelot.h` header and correctly has
  `select REGMAP_MMIO`. `PINCTRL_INGENIC`, `PINCTRL_K210`, `PINCTRL_K230` also correctly
  `select REGMAP_MMIO`. `PINCTRL_MICROCHIP_SGPIO` is the only one missing it.

  **Trigger config:** `configs/archive_failed/kconfig-rand500config-arm64-v7.2-rc2-edfe557442df5e93de92b3b3cca7c8a36183e28da1169bd8c7112e462b33b42a-BUILD_FAIL.config`

  **Reproduce:** `make checkout TAG=v7.2-rc2 && make replay CONFIG_FILE=<above>`

  **Fix** — `drivers/pinctrl/Kconfig` (tab-indented, same as sibling drivers):
  ```diff
   config PINCTRL_MICROCHIP_SGPIO
  +	select REGMAP_MMIO
  ```

  **Fix confirmed:** replay with original failing config after applying the patch:
  - SHA changed: `edfe557442df5e93...` → `60276c6208800aca...` (olddefconfig auto-added REGMAP_MMIO=y)
  - Build: PASS, Boot: PASS, Tests: 26/26 — v7.2-rc2 arm64

  **Patch — not yet submitted to mailing list (2026-07-18)**

  Subsystem: PIN CONTROL (`drivers/pinctrl/`). Introduced by commit
  `68c873363a78` ("pinctrl: microchip-sgpio: add ability to be used in a
  non-mmio configuration"), present since 2022, affects all stable branches.

  Recipients:
  ```
  To:  Linus Walleij <linusw@kernel.org>
  Cc:  Steen.Hegelund@microchip.com
  Cc:  daniel.machon@microchip.com
  Cc:  UNGLinuxDriver@microchip.com
  Cc:  linux-gpio@vger.kernel.org
  Cc:  linux-arm-kernel@lists.infradead.org
  Cc:  linux-kernel@vger.kernel.org
  Cc:  stable@vger.kernel.org
  ```

  Commit message:
  ```
  Subject: [PATCH] pinctrl: microchip-sgpio: add missing select REGMAP_MMIO

  The driver includes <linux/mfd/ocelot.h>, which calls
  ocelot_regmap_from_resource() -> devm_regmap_init_mmio(). Both the
  function and struct regmap_config are guarded by #ifdef CONFIG_REGMAP
  in <linux/regmap.h>. CONFIG_REGMAP is only auto-selected when something
  selects CONFIG_REGMAP_MMIO.

  Without 'select REGMAP_MMIO' in the Kconfig entry, a config that
  enables PINCTRL_MICROCHIP_SGPIO without any other driver pulling in
  REGMAP_MMIO fails to build:

    include/linux/mfd/ocelot.h:19:51: warning: 'struct regmap_config'
      declared inside parameter list will not be visible outside of
      this definition or declaration
    include/linux/mfd/ocelot.h:34:24: error: implicit declaration of
      function 'devm_regmap_init_mmio'
    drivers/pinctrl/pinctrl-microchip-sgpio.c:910:16: error: variable
      'regmap_config' has initializer but incomplete type
    drivers/pinctrl/pinctrl-microchip-sgpio.c:911:18: error: 'struct
      regmap_config' has no member named 'reg_bits'

  PINCTRL_OCELOT uses the same ocelot.h header and correctly has
  'select REGMAP_MMIO'. Fix PINCTRL_MICROCHIP_SGPIO the same way.

  Fixes: 68c873363a78 ("pinctrl: microchip-sgpio: add ability to be used in a non-mmio configuration")
  Cc: stable@vger.kernel.org
  Signed-off-by: Benjamin Boortz <benjamin.boortz@gmail.com>
  ---
   drivers/pinctrl/Kconfig | 1 +
   1 file changed, 1 insertion(+)

  diff --git a/drivers/pinctrl/Kconfig b/drivers/pinctrl/Kconfig
  --- a/drivers/pinctrl/Kconfig
  +++ b/drivers/pinctrl/Kconfig
  @@ -425,6 +425,7 @@ config PINCTRL_MICROCHIP_SGPIO
   	select GENERIC_PINCONF
   	select GENERIC_PINCTRL_GROUPS
   	select GENERIC_PINMUX_FUNCTIONS
  +	select REGMAP_MMIO
   	help
  ```

  Send with:
  ```sh
  cd ~/git/linux
  git add drivers/pinctrl/Kconfig && git commit
  scripts/checkpatch.pl --strict $(git format-patch -1 --stdout)
  git send-email --to='linusw@kernel.org' \
    --cc='Steen.Hegelund@microchip.com' \
    --cc='daniel.machon@microchip.com' \
    --cc='UNGLinuxDriver@microchip.com' \
    --cc='linux-gpio@vger.kernel.org' \
    --cc='linux-arm-kernel@lists.infradead.org' \
    --cc='linux-kernel@vger.kernel.org' \
    --cc='stable@vger.kernel.org' \
    $(git format-patch -1)
  ```

---

## 2026-07-21 — v7.2-rc4 rand500config Boot Failures (10-run sweep)

### High — Kernel Crash

- [ ] **`CONFIG_RCU_SCALE_TEST=y` triggers NULL pointer dereference in `rcu_scale_writer` on i386**
  Kernel: v7.2-rc4. Arch: i386. Found in 2 of 10 rand500config/i386 runs.

  Both failing configs have `CONFIG_RCU_SCALE_TEST=y`. After the scale test completes
  100 measurements the writer task crashes with a write fault (Oops code 0002) at
  address 0x00000000 — a NULL pointer write:

  ```
  BUG: kernel NULL pointer dereference, address: 00000000
  Oops: Oops: 0002 [#1]
  CPU: 0 PID: 17 Comm: rcu_scale_write  7.2.0-rc4
  EIP: rcu_scale_writer+0x497/0x4b0
  note: rcu_scale_write[17] exited with irqs disabled
  ```

  The second oops config lacks `CONFIG_KALLSYMS` so EIP resolves to a raw address
  (`0xc105fb2b`), but the sequence is identical: 100 measurements → NULL write → irqs
  disabled on exit.

  **Both configs differ significantly** (different CPU targets, different subsystems
  enabled) — the only shared factor relevant to this crash is `CONFIG_RCU_SCALE_TEST=y`.

  **Root cause:** Unknown. Likely a bug in `kernel/rcu/rcuscale.c` on i386 where
  `rcu_scale_writer` writes through a pointer that is NULL after the first measurement
  batch. Could be an i386-specific alignment or pointer arithmetic issue.

  **Trigger configs:**
  ```
  configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-22799f...BOOT_FAIL-oops.config
  configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-90748f...BOOT_FAIL-oops.config
  ```

  **Reproduce:**
  ```sh
  make replay CONFIG_FILE=configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-22799f1390815c3a0bc53894af09fecc99ae7a62245377f3f0938010604dc225-BOOT_FAIL-oops.config CONFIGS=rand500config ARCHS=i386
  ```

  **Next steps:**
  - Replay to confirm consistent reproduction
  - Check if `CONFIG_RCU_EXPERT=y` (present in run 1 config) is required to trigger
  - Check `kernel/rcu/rcuscale.c` around `rcu_scale_writer` offset 0x497 on i386
  - Consider adding `CONFIG_RCU_SCALE_TEST=n` to `configs/randconfig.config` (sibling
    to the already-excluded `CONFIG_RCU_TORTURE_TEST`) to stop this appearing in future
    sampling, pending upstream investigation

  **Subsystem:** RCU (`kernel/rcu/`). Maintainer: Paul McKenney / Joel Fernandes.
  Mailing list: `rcu@vger.kernel.org`, `linux-kernel@vger.kernel.org`.

### Low — Boot Failure (single occurrence)

- [ ] **arm64: init crashes with SIGSEGV (exitcode=0x0000000b) on one rand500config**
  Kernel: v7.2-rc4. Arch: arm64. Found in 1 of 10 runs (config SHA: `d2d7a42d...`).

  ```
  Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
  ```

  `exitcode=0x0000000b` = signal 11 (SIGSEGV). The toybox `/init` process crashed with
  a segfault before any tests ran. No backtrace captured (CONFIG_KALLSYMS status unknown
  for this config).

  **Not yet reproducible:** Only one occurrence. Could be a missing kernel feature that
  toybox requires (BPF, compat32, specific syscall) or a real kernel mm/exec bug.

  **Next step:** Replay the archived config and inspect full dmesg for what init was doing
  at the point of crash:
  ```sh
  make replay CONFIG_FILE=configs/archive_failed/kconfig-rand500config-arm64-v7.2-rc4-d2d7a42d5a261ceb37b934aef3b2f4e98d3a033c0b9d0146ab64d5e5383902fe-BOOT_FAIL-kernel-panic.config CONFIGS=rand500config ARCHS=arm64
  ```

---

## 2026-07-22 — Stable Kernel (7.1.x) KUnit: gpu_buddy 32-bit Bug

### High — Kernel Bug (i386-only, deterministic)

- [ ] **`gpu_test_buddy_alloc_exceeds_max_order` KUnit fails on i386 — `roundup_pow_of_two` silently truncates `u64` to 32-bit**
  Kernel: stable v7.1.3 (first found), v7.1.4 (confirmed). Also present in mainline v7.2 (`drivers/gpu/buddy.c:1356`). Arch: i386 only. Found by kunitrandconfig/i386 sweep.

  **Test failure output:**
  ```
  # KTAP version 1
  # Subtest: gpu_buddy
  not ok 15 gpu_test_buddy_alloc_exceeds_max_order
  # EXPECTATION FAILED at drivers/gpu/tests/gpu_buddy_test.c:1379
  # Expected err == -22, but err == 0 (0x0)
  # gpu_buddy_fini:474: GPU BUG: assertion `gpu_buddy_block_is_free(mm->roots[i])` failed
  # gpu_buddy_fini:482: GPU BUG: assertion `mm->avail == mm->size` failed
  not ok 16 gpu_buddy
  ```
  Result: `KUNIT_FAIL-2-of-1749` on both v7.1.3 and v7.1.4. All other 1747 KUnit tests pass.

  **Root cause — `roundup_pow_of_two` is not `u64`-safe on 32-bit systems:**

  `gpu_buddy_alloc_blocks` (`drivers/gpu/buddy.c:1321`) calls:
  ```c
  u64 size = SZ_8G + SZ_1G;   /* 0x240000000 — a 64-bit value */
  size = roundup_pow_of_two(size);  /* BUG: not u64-safe */
  ```

  `roundup_pow_of_two` dispatches to `__roundup_pow_of_two(unsigned long n)` (`include/linux/log2.h:55`).
  On i386, `unsigned long` is 32 bits. The function argument conversion silently truncates
  `0x240000000` → `0x40000000 = SZ_1G`.

  **Execution trace on i386:**
  | Step | Expected (64-bit) | Actual on i386 |
  |------|-------------------|----------------|
  | `roundup_pow_of_two(0x240000000)` | `0x400000000 = SZ_16G` | `0x40000000 = SZ_1G` (truncated) |
  | `pages = size >> 12` | `0x400000` (order=22) | `0x40000` (order=18) |
  | `order > mm->max_order(21)?` | TRUE → return -EINVAL | FALSE → continues |
  | `size > mm->size(SZ_10G)?` | TRUE → return -EINVAL | FALSE (SZ_1G < SZ_10G) → continues |
  | Return value | -EINVAL | 0 (allocation succeeds) |

  Because the guard at `buddy.c:1335–1342` is never triggered, the function allocates
  `SZ_1G` bytes instead of rejecting the over-limit request. `gpu_buddy_fini` then fires
  internal assertions because the block was never freed (lines 474, 482 are secondary effects).

  **Why x86_64 passes:** `unsigned long` is 64 bits on x86_64, so `roundup_pow_of_two` handles
  `u64` correctly and the overflow guard fires as expected.

  **Evidence — code references:**
  - Test: `drivers/gpu/tests/gpu_buddy_test.c:1350–1382` (`gpu_test_buddy_alloc_exceeds_max_order`)
  - Bug site: `drivers/gpu/buddy.c:1321` (stable), `drivers/gpu/buddy.c:1356` (mainline)
  - Truncation: `include/linux/log2.h:55` (`__roundup_pow_of_two(unsigned long n)`)
  - Guard that should fire: `drivers/gpu/buddy.c:1335–1342`

  **Trigger configs (same logical bug, different random KUnit module sets):**
  ```
  kernel-test-stable/configs/archive_failed/kconfig-kunitrandconfig-i386-v7.1.3-35376dd938df26e368915a706ef26053aec3e6bee302d3825dc0a774007f46fa-KUNIT_FAIL-2-of-1749.config
  ```
  v7.1.4 replay config SHA: `fae25d2690989975c4845d09d204d61a64e7aa9fe4b01891e291bf848aa3652c` (same failure)

  **Reproduce:**
  ```sh
  cd ~/git/kernel-test-stable
  make checkout TAG=v7.1.4
  make replay CONFIG_FILE=configs/archive_failed/kconfig-kunitrandconfig-i386-v7.1.3-35376dd938df26e368915a706ef26053aec3e6bee302d3825dc0a774007f46fa-KUNIT_FAIL-2-of-1749.config NO_FETCH=1
  # Expect: kunit:1747/1749 FAIL — gpu_test_buddy_alloc_exceeds_max_order + gpu_buddy suite
  ```

  **Fix** — `drivers/gpu/buddy.c` (same line number differs by 35 between stable and mainline):
  ```diff
  -		size = roundup_pow_of_two(size);
  +		size = BIT_ULL(fls64(size - 1));
  ```
  `BIT_ULL(fls64(size - 1))` is equivalent to `roundup_pow_of_two` but uses 64-bit
  `fls64` instead of 32-bit `fls_long`, and `1ULL` instead of `1UL`. For the test case:
  `fls64(0x23FFFFFFF) = 34` → `BIT_ULL(34) = 0x400000000 = SZ_16G` ✓

  **Subsystem:** `drivers/gpu/` (GPU memory management). Maintainers: Christian König, Thomas Hellström.
  Mailing lists: `dri-devel@lists.freedesktop.org`, `linux-kernel@vger.kernel.org`.
  Cc `stable@vger.kernel.org` — same bug present in all stable branches that carry the gpu_buddy allocator.

  **Patch recipients:**
  ```
  To:  Christian König <christian.koenig@amd.com>
  To:  Thomas Hellström <thomas.hellstrom@linux.intel.com>
  Cc:  dri-devel@lists.freedesktop.org
  Cc:  linux-kernel@vger.kernel.org
  Cc:  stable@vger.kernel.org
  ```

  **Tinyconfig reproducer:**

  The kunitrandconfig trigger config is large (1749 tests, ~100 MB kernel). A minimal
  reproducer isolates the failure to a single test suite and is better for LKML.

  *Dependency chain* — why GATE_CFGS are needed:
  ```
  GPU_BUDDY_KUNIT_TEST  →  depends on GPU_BUDDY && KUNIT
                                       |
                               GPU_BUDDY (bool, no prompt — selected-only)
                                       |
                               selected by DRM_BUDDY (tristate, no prompt — hidden)
                                       |
                               depends on DRM (menuconfig, user-selectable on i386)
                                       |
                               depends on (AGP || AGP=n) && !EMULATED_CMPXCHG && HAS_DMA
                                        ✓ all satisfied on i386
  ```
  `DRM_BUDDY` and `GPU_BUDDY` have no Kconfig `prompt` — they cannot be enabled by the
  user via `make menuconfig` and are normally only pulled in by heavy GPU drivers (i915,
  amdgpu, xe). However, `make olddefconfig` keeps any option in `.config` whose `depends on`
  chain is satisfied, regardless of whether it has a prompt. Appending `CONFIG_DRM_BUDDY=y`
  to the fragment before `olddefconfig` is enough — it stays because `depends on DRM` is met.

  *Using the harness* — one command, fully automated:
  ```sh
  # In kernel-test or kernel-test-stable, after make checkout TAG=<version>:
  make kconfig-build SUBSYSTEM=gpu ARCHS=i386 GATE_CFGS=CONFIG_DRM,CONFIG_DRM_BUDDY DRY_RUN=1
  # Preview: shows CONFIG_GPU_BUDDY and CONFIG_GPU_BUDDY_KUNIT_TEST will be swept

  make kconfig-build SUBSYSTEM=gpu ARCHS=i386 GATE_CFGS=CONFIG_DRM,CONFIG_DRM_BUDDY
  # Runs: tinyconfig + randkconfigconfig.config + DRM=y + DRM_BUDDY=y + GPU_BUDDY_KUNIT_TEST=y
  # Builds and boots each option; GPU_BUDDY_KUNIT_TEST will show KUNIT_FAIL-1/N
  ```
  The sweep generates one build per Kconfig entry in `drivers/gpu/Kconfig`. Only
  `GPU_BUDDY_KUNIT_TEST` triggers a KUnit run; `GPU_BUDDY` is a plain bool with no test.

  *Manual fragment* — for a standalone reproducer outside the harness (e.g. for LKML):
  ```sh
  # 1. Generate minimal base config for i386
  make -C ~/git/linux-stable tinyconfig ARCH=i386 O=/tmp/repro-gpu-buddy

  # 2. Apply bootability + KUnit + GPU buddy test
  cat >> /tmp/repro-gpu-buddy/.config <<'EOF'
  # Bootability (same as configs/randkconfigconfig.config)
  CONFIG_TTY=y
  CONFIG_SERIAL_8250=y
  CONFIG_SERIAL_8250_CONSOLE=y
  CONFIG_BLK_DEV_INITRD=y
  CONFIG_BINFMT_ELF=y
  CONFIG_BINFMT_SCRIPT=y
  # KUnit framework
  CONFIG_KUNIT=y
  # Gate symbols (DRM + hidden DRM_BUDDY, which selects GPU_BUDDY)
  CONFIG_DRM=y
  CONFIG_DRM_BUDDY=y
  # Target test
  CONFIG_GPU_BUDDY_KUNIT_TEST=y
  EOF

  # 3. Resolve dependencies (olddefconfig keeps DRM_BUDDY=y because depends on DRM is met)
  make -C ~/git/linux-stable ARCH=i386 O=/tmp/repro-gpu-buddy olddefconfig

  # 4. Verify the key options survived
  grep -E "CONFIG_(DRM|GPU_BUDDY|KUNIT)" /tmp/repro-gpu-buddy/.config

  # 5. Build
  make -C ~/git/linux-stable ARCH=i386 O=/tmp/repro-gpu-buddy -j$(nproc) bzImage

  # 6. Boot in QEMU (minimal — no initramfs needed, KUnit runs before /init)
  qemu-system-i386 -kernel /tmp/repro-gpu-buddy/arch/x86/boot/bzImage \
    -append "console=ttyS0 earlycon=uart8250,io,0x3f8 panic=5" \
    -serial stdio -display none -no-reboot -m 512
  ```

  *Expected output in QEMU serial log:*
  ```
  KTAP version 1
  # Subtest: gpu_buddy
  ok 1 gpu_test_buddy_alloc_limit
  ...
  not ok 15 gpu_test_buddy_alloc_exceeds_max_order
  # EXPECTATION FAILED at drivers/gpu/tests/gpu_buddy_test.c:1379
  # Expected err == -22, but err == 0 (0x0)
  not ok 16 gpu_buddy
  ```
  Only 16 test cases run (the full `gpu_buddy` suite), compared to 1749 in kunitrandconfig —
  output is unambiguous and the failure stands alone.

  **Commit message:**
  ```
  Subject: [PATCH] drm/buddy: fix roundup_pow_of_two() truncation on 32-bit arches

  gpu_buddy_alloc_blocks() rounds the requested allocation size up to
  the nearest power of two using roundup_pow_of_two(), which internally
  calls __roundup_pow_of_two(unsigned long). On 32-bit architectures,
  unsigned long is 32 bits, so passing a u64 value larger than UINT32_MAX
  silently truncates it before the rounding.

  With mm_size = SZ_8G + SZ_2G and a CONTIGUOUS|RANGE request for
  SZ_8G + SZ_1G:

    Expected: roundup_pow_of_two(0x240000000) = 0x400000000 (SZ_16G)
    Actual:   roundup_pow_of_two(0x040000000) = 0x040000000 (SZ_1G)
              (0x240000000 truncated to 32-bit → 0x040000000)

  After truncation, order=18 does not exceed max_order=21 and size=SZ_1G
  does not exceed mm->size=SZ_10G, so the -EINVAL guard at line 1335 is
  never reached. The allocation succeeds, and gpu_buddy_fini() subsequently
  fires internal assertions because the block was never freed.

  This is caught by the KUnit test gpu_test_buddy_alloc_exceeds_max_order,
  which fails on i386 with:
    Expected err == -22, but err == 0
    gpu_buddy_fini:474: GPU BUG: assertion failed
    gpu_buddy_fini:482: GPU BUG: assertion failed

  Fix by using BIT_ULL(fls64(size - 1)) instead of roundup_pow_of_two(),
  which performs the equivalent operation in 64 bits on all architectures.

  Fixes: <commit that introduced gpu_buddy_alloc_blocks with CONTIGUOUS path>
  Cc: stable@vger.kernel.org
  Signed-off-by: Benjamin Boortz <benjamin.boortz@gmail.com>
  ---
   drivers/gpu/buddy.c | 2 +-
   1 file changed, 1 insertion(+), 1 deletion(-)

  diff --git a/drivers/gpu/buddy.c b/drivers/gpu/buddy.c
  --- a/drivers/gpu/buddy.c
  +++ b/drivers/gpu/buddy.c
  @@ -1318,7 +1318,7 @@ int gpu_buddy_alloc_blocks(...)
   	/* Roundup the size to power of 2 */
   	if (flags & GPU_BUDDY_CONTIGUOUS_ALLOCATION) {
  -		size = roundup_pow_of_two(size);
  +		size = BIT_ULL(fls64(size - 1));
   		min_block_size = size;
  ```

  **Status:** Not yet submitted. Find the exact `Fixes:` commit with:
  ```sh
  cd ~/git/linux
  git log --oneline drivers/gpu/buddy.c | grep -i "contiguous\|round\|power"
  ```

---

## 2026-07-22 — v7.2-rc4 rand500config Boot Failure: DEBUG_TEST_DRIVER_REMOVE + IIO drivers

### Medium — Boot Failure (complex N-way interaction, not yet actionable for LKML)

- [ ] **`CONFIG_DEBUG_TEST_DRIVER_REMOVE=y` + multiple IIO drivers causes BOOT_FAIL on i386 — minimal reproducer not isolated**
  Kernel: v7.2-rc4. Arch: i386. Found by config bisect (`make bisect`) on
  `kconfig-rand500config-i386-v7.2-rc4-1130034ad8bb931d733ad604ddf6a0eec3d97fa5574b93987a3fa55fa933cb89-BOOT_FAIL-timeout.config`.

  **What `CONFIG_DEBUG_TEST_DRIVER_REMOVE` does:** After each successful `->probe()`, immediately
  calls `->remove()` then re-probes the driver. This stress-tests remove/re-probe paths and can
  expose deadlocks or infinite loops in drivers that handle remove incorrectly.

  **Failure symptom:** `Did not reach init (QEMU exit 0)` — QEMU exits cleanly before the kernel
  reaches `/init`. No oops/panic on the console; the kernel likely stalled or halted during
  a driver's remove+re-probe cycle.

  **Trigger config:**
  ```
  configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-1130034ad8bb931d733ad604ddf6a0eec3d97fa5574b93987a3fa55fa933cb89-BOOT_FAIL-timeout.config
  ```

  **Multi-pass bisect result (6 passes, ~3 h total):**

  Six rounds of `make bisect` with `PINNED_OPTS=` accumulating each suspect were run.
  Every pass consistently narrowed to the left (alphabetically-first) half, indicating
  all required options reside in the alphabetically-early part of the 150-option candidate space.

  | Pass | Pinned | New suspect found | Verify alone |
  |------|--------|-------------------|--------------|
  | 1 | — | `CONFIG_DEBUG_TEST_DRIVER_REMOVE=y` | PASS (needs more) |
  | 2 | DEBUG_TEST_DRIVER_REMOVE | `CONFIG_AD7405=y` | PASS (needs more) |
  | 3 | + AD7405 | `CONFIG_AD7606_IFACE_PARALLEL=y` | PASS (needs more) |
  | 4 | + AD7606_IFACE_PARALLEL | `CONFIG_AD7606=y` | PASS (needs more) |
  | 5 | + AD7606 | `CONFIG_AUTOFS_FS=y` | PASS (needs more) |
  | 6 | + AUTOFS_FS | `CONFIG_BMC150_ACCEL=y` | PASS (needs more) |

  **Pattern:** Four of the five co-suspects (AD7405, AD7606, AD7606_IFACE_PARALLEL, BMC150_ACCEL)
  are all IIO (Industrial I/O) subsystem drivers from Analog Devices / Bosch. The bisect also found
  `CONFIG_AUTOFS_FS=y`, which is unrelated to IIO and is likely a bisect artifact (it happened to be
  alphabetically adjacent to the IIO drivers in the left half and was not individually required).

  **Root cause hypothesis:** `CONFIG_DEBUG_TEST_DRIVER_REMOVE` exercises driver probe/remove
  at boot. One or more IIO drivers (AD7405, AD7606, BMC150_ACCEL) have a buggy remove path on
  i386 that hangs or panics, causing the guest to shut down before reaching `/init`. The IIO
  infrastructure options (`CONFIG_IIO=y`, `CONFIG_IIO_BUFFER=y`, etc.) are also in the candidate
  set and are likely auto-selected when the IIO drivers are present.

  **Why the bisect did not converge:** The failure requires a combination of options that all
  happen to reside in the same alphabetically-first half of the candidate space. The PINNED_OPTS
  mechanism correctly identifies one option per pass, but when multiple co-required options are
  concentrated in the same half, the bisect must do one pass per required option. With 4+ IIO
  options needed, convergence would require additional passes with diminishing returns and no
  guarantee the final set is minimal.

  **Status:** Not actionable for LKML without a minimal 1–2 option reproducer. The interaction
  is real (full config + pinned suspects reliably fails; baseline passes) but the exact minimal
  set has not been isolated.

  **Next steps if revisiting:**
  - Test `CONFIG_DEBUG_TEST_DRIVER_REMOVE=y` + `CONFIG_IIO=y` (framework only, no specific
    driver) to see if the IIO core is sufficient without the AD7xxx drivers
  - Test `CONFIG_DEBUG_TEST_DRIVER_REMOVE=y` + `CONFIG_AD7606=y` + `CONFIG_AD7606_IFACE_PARALLEL=y`
    (a coherent driver + its interface option) to see if that pair is sufficient
  - If either 2-option test reproduces, file as a driver remove path bug in the IIO subsystem

---

## 2026-07-22 — v7.2-rc4 rand500config/i386: DEBUG_TEST_DRIVER_REMOVE breaks serial console

### High — Kernel Bug (single-option reproducer, actionable)

- [ ] **`CONFIG_DEBUG_TEST_DRIVER_REMOVE=y` alone breaks serial console on i386 — BOOT_FAIL-no-console**
  Kernel: v7.2-rc4. Arch: i386. Found by config bisect (`make bisect`) on
  `kconfig-rand500config-i386-v7.2-rc4-b7e535b388917a55c2c870494459ea80668d073efe99d0760fabcaf5a3ec656d-BOOT_FAIL-no-console.config`.

  **Bisect result:** `CONFIG_DEBUG_TEST_DRIVER_REMOVE=y` confirmed as the sole responsible option.
  Verified alone on a tinyconfig+bootability baseline: `BOOT_FAIL-no-console` reproduces with
  only this one option added. No co-required options.

  **Canary diagnosis:** `CANARY_EARLY=reached` — the raw UART `early_initcall` marker fired,
  confirming the kernel ran past `do_initcalls()`. The kernel is alive; the serial console
  driver was silently broken after the canary fired.

  **Mechanism:** `CONFIG_DEBUG_TEST_DRIVER_REMOVE` calls `->remove()` immediately after each
  successful `->probe()`, then re-probes. The 8250 UART driver (`CONFIG_SERIAL_8250_CONSOLE`)
  is among the drivers probed during boot. When it is removed and re-probed, the console
  registration (`console_tryregister()` / `uart_add_one_port()`) is apparently not re-established
  correctly, leaving the serial console silent for the rest of boot.

  **Relationship to prior finding (IIO interaction):** The previous `BOOT_FAIL-timeout`
  (kernel boots but never reaches init, requires DEBUG_TEST_DRIVER_REMOVE + multiple IIO drivers)
  is a separate failure mode — likely a deadlock or hang in an IIO driver's remove path. This
  is a distinct, simpler bug: the remove+re-probe of the UART console driver itself breaks
  console output, which is observable even without any IIO drivers present.

  **Minimal reproducer archived:**
  ```
  configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-a036ae3817c6b36ee468e644441358abb6b52765d83ea5217b860bd07d613254-BOOT_FAIL-no-console-bisect-from-b7e535b388917a55c2c870494459ea80668d073efe99d0760fabcaf5a3ec656d.config
  ```

  **Reproduce:**
  ```sh
  make bisect CONFIG_FILE=configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-b7e535b388917a55c2c870494459ea80668d073efe99d0760fabcaf5a3ec656d-BOOT_FAIL-no-console.config
  # or replay the minimal reproducer directly:
  make replay CONFIG_FILE=configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-a036ae3817c6b36ee468e644441358abb6b52765d83ea5217b860bd07d613254-BOOT_FAIL-no-console-bisect-from-b7e535b388917a55c2c870494459ea80668d073efe99d0760fabcaf5a3ec656d.config CONFIGS=rand500config ARCHS=i386
  ```

  **Next steps:**
  - Confirm on x86_64 to determine if the bug is i386-specific
  - Reproduce with a manual tinyconfig + `CONFIG_SERIAL_8250_CONSOLE=y` + `CONFIG_DEBUG_TEST_DRIVER_REMOVE=y` to get the minimal kernel config for LKML
  - Inspect `drivers/tty/serial/8250/8250_core.c` remove/probe path for console re-registration
  - File as a `CONFIG_DEBUG_TEST_DRIVER_REMOVE` + 8250 interaction bug

  **Subsystem:** `drivers/tty/serial/8250/` or `drivers/base/` (driver core). Mailing list:
  `linux-serial@vger.kernel.org`, `linux-kernel@vger.kernel.org`.

---

## Finding Status Summary

| Status | Count |
|--------|-------|
| Open   | 5     |
| Resolved | 16  |
| Won't fix | 0  |
| Reconsider later | 0 |
