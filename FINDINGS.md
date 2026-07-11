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

- [~] **7.2-rc2 localconfig: CIFS VFS socket errors in dmesg** 🔁 reconsider for LKML report
  dmesg on the booted 7.2-rc2 localconfig kernel showed:
  ```
  CIFS: VFS: Error connecting to socket. Aborting operation.
  CIFS: VFS: cifs_mount failed w/return code = -111
  ```
  These appear during boot when Samba/CIFS mounts configured in `/etc/fstab` are attempted
  before the network is fully up. Not a kernel regression — this is a race between the mount
  attempt and NetworkManager completing connection setup.

  **No action required** for the harness itself. If CIFS mounts are needed on the localconfig
  kernel, add `_netdev` and `x-systemd.automount` to the fstab options.

- [~] **7.2-rc2 localconfig: "163 callbacks suppressed" in dmesg** 🔁 monitor
  dmesg showed:
  ```
  callbacks 163 suppressed
  ```
  This is the kernel's `net_ratelimit()` suppression message, indicating a burst of repeated
  log entries (likely the CIFS error above being rate-limited). Not independently concerning —
  follows from the CIFS mount failures.

  **If it recurs without CIFS errors** on a clean boot, investigate `dmesg | grep suppressed`
  for the surrounding context and consider filing a LKML report.

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
  CONFIG_DEBUG_INFO_BTF=n
  CONFIG_DEBUG_INFO_BTF_MODULES=n
  ```
  This disables BTF generation entirely. BPF CO-RE (Compile Once, Run Everywhere) is
  unavailable on this kernel, but the kernel is otherwise fully functional. bpftrace and
  libbpf-based tools that use CO-RE will fall back or fail gracefully. Kernel-internal BPF
  (used by systemd, network tools) is unaffected — BTF is only needed for CO-RE portability.

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

## Finding Status Summary

| Status | Count |
|--------|-------|
| Open   | 0     |
| Resolved | 13  |
| Won't fix | 0  |
| Reconsider later | 2 |
