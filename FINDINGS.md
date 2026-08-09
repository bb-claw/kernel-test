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


---

## 2026-08-08 — 320_ns-net: false positive when CONFIG_IPV6_SIT=y (built-in)

### Fixed — Test Correctness

- [x] **`ns-net proc-net` false positive: `sit0` appears in new net namespace when CONFIG_IPV6_SIT is built-in** ✅ resolved 2026-08-08
  Found by `make extended NO_FETCH=1` on stable-rc clone (v7.1.8-rc1, randdefconfig/arm64).
  All 19 other config/arch combos passed; only randdefconfig/arm64 failed `320_ns-net`.

  **Symptom:** `FAIL: net: ns-net proc-net failed (init_net leak regression?)` — misleading,
  looked like an init_net namespace isolation regression.

  **Root cause:** `ns-net proc-net` (C binary) called `unshare(CLONE_NEWNET)` then read
  `/proc/net/dev` and failed if any interface other than `lo` was present. When
  `CONFIG_IPV6_SIT=y` (built-in), the kernel creates a per-namespace `sit0` admin tunnel
  device in every new network namespace — this is correct kernel behaviour, not a leak.

  `randdefconfig` with `CONFIG_MODULES=n` (one of the 300 randomly disabled options) forces
  `CONFIG_IPV6_SIT=m` → `=y` (built-in). `defconfig/arm64` has `=m` so the module is not
  loaded in the initramfs environment and no `sit0` appears — hence defconfig passed.

  `/proc/net/dev` in the new namespace showed:
  ```
      lo:       0       0    0    0    0     0          0         0 ...
    sit0:       0       0    0    0    0     0          0         0 ...
  ```
  `sit0` is a per-namespace SIT tunnel base device, not init_net leaking.

  **Fix:** `tests/ns/ns-net.c` — added a whitelist of per-namespace admin tunnel base
  devices that built-in drivers create in every new namespace:
  ```c
  static const char * const perns_admin_ifaces[] = {
      "lo:", "sit0:", "ip6tnl0:", "ip_vti0:", "ip6gre0:",
      "gre0:", "gretap0:", "ip6erspan0:", "erspan0:", NULL,
  };
  ```
  `proc-net` now only reports failure if an interface not in this whitelist appears.
  The error message was also improved to print the unexpected interface name.

  **Trigger config archived in kernel-test-data:**
  ```
  configs/archive_failed/kconfig-randdefconfig-arm64-v7.1.8-rc1-69a125ea...-TEST_FAIL-ns-net-init_net-leak.config
  ```

  **Reproduce (stable-rc clone, before fix):**
  ```sh
  cd ~/git/kernel-test-stable-rc
  make replay CONFIG_FILE=../kernel-test-data/configs/archive_failed/kconfig-randdefconfig-arm64-v7.1.8-rc1-69a125ea869ae2968ab1b33adb4f6e88818b40e08f35f120f2e25149e9a161e8-TEST_FAIL-ns-net-init_net-leak.config CONFIGS=randdefconfig ARCHS=arm64 NO_FETCH=1
  ```

  **After fix:** replay of same config → 43/43 PASS.

> Kernel bug findings moved to [kernel-test-data/FINDINGS.md](https://github.com/bb-claw/kernel-test-data/blob/main/FINDINGS.md)

---

## 2026-08-09 — VisionFive 2 hw-test: Toybox sh SIGSEGV in subprocesses

### Low — Benign crash noise during VF2 hardware test runs

- [~] **Toybox 0.8.14 sh subprocesses SIGSEGV during hw-test on VF2 (multi-core RISC-V)** — primary fix applied (see next-steps #1); root cause not fully confirmed; monitor on next hw-test run

  **Environment:**
  - Board: StarFive VisionFive 2 v1.2A (JH7110 SoC, 4-core RISC-V rv64imafdcsu)
  - Kernel: 7.2.0-rc6-vf2 (vf2config, riscv arch)
  - Toybox: 0.8.14 — statically linked `toybox-riscv64` from Toybox project
  - Initramfs: standard kernel-test initramfs built by `lib/initramfs.sh`

  **Symptom:**
  The serial capture (`dmesg.txt`) contains 6+ entries of the form:
  ```
  sh[230]: unhandled signal 11 code 0x1 at 0x000000732a2e2a27 in toybox[21312,10000+ad000]
  sh[379]: unhandled signal 11 code 0x1 at 0x000000732a2e2727 in toybox[21312,10000+ad000]
  ```
  The crashes interleave with test output mid-line (e.g. `ok: bind mount: entry presen[CRASH DUMP]t in /proc/mounts`),
  confirming the crashing process was running concurrently on a different CPU core. Despite the
  crashes, **all tests PASS or FAIL correctly** — the test count and outcomes are not affected.

  Observed crashing PIDs in one run: 230, 379, 394, 417, 428, 430 (all `comm: sh`).
  Tests whose output is interleaved with a crash: 040, 210, 230, 260, 270, 280.

  **Impact:** None on test correctness. The crash dump lines are cosmetic noise in the serial
  log. The `parse_serial_output` function looks for `^< TEST PASS:` / `^< TEST FAIL:` markers
  which are unambiguous; crash dump lines don't match those patterns.

  **Crash site analysis (binary: `cache/toybox-riscv64`, text segment VMA 0x10000):**

  | Register | Value | Meaning |
  |---|---|---|
  | `epc` | `0x31312` | Faulting instruction: `lbu a5, 0(a1)` — load first byte of string |
  | `ra` | `0x33950` | Return address inside `setup_env`: just after call at `0x3394c` |
  | `a0` | `0x719f0` | .rodata constant: `"USER"` (the env var name being set) |
  | `a1` | `0x000000732a2e2a27` | Should be `pw->pw_name` — contains an invalid pointer |
  | `a2` | `0xcbee8` | Fallback buffer (512 bytes past the struct passwd) |

  The crash is in a small helper called by `setup_env` (starting near `0x337f4`):
  ```asm
  ; helper at 0x31310 — setenv with NULL/empty guard
  31310:  beqz a1, 0x3131a     ; if pw_name == NULL, use fallback
  31312:  lbu  a5, 0(a1)       ; ← CRASH: a1 is a non-NULL invalid pointer
  31316:  beqz a5, 0x3131a     ; if pw_name is empty string, use fallback
  31318:  mv   a2, a1          ; use pw_name as the env value
  3131a:  mv   a1, a2
  3131c:  j    0x2e76c         ; call setenv
  ```

  The caller at `0x3393c–0x3394c` loads `a1 = *(s2 + 0)` where `s2` points to the fallback
  `struct passwd` at VMA `0xcbae8` (BSS section, offset `0x1058` from BSS base `0xcaa90`).
  The struct is zero-initialised in a freshly exec'd process, so `pw_name` starts as `NULL`;
  the NULL guard at `0x31310` handles that case correctly.

  The crash only occurs when `pw_name` holds a **non-NULL invalid pointer** — meaning something
  has written a non-zero value to BSS address `0xcbae8` before `setup_env` runs its USER step.

  **Root cause hypothesis:**
  Toybox's NOFORK execution model runs many applets (grep, cat, wc, head, …) directly inside
  the calling sh process without fork/exec. All applets share the same BSS. Toybox's global
  applet state is a large union (`TT`) also in BSS. If a field of `TT` for some specific applet
  overlaps with BSS+`0x1058` (i.e. `pw_name` of the fallback passwd struct), running that
  applet NOFORK writes a non-zero value there. The next time a **new sh process is exec'd**
  (fork+exec, running fresh `setup_env`) it finds the global struct pre-corrupted because the
  kernel BSS-zeroing applies only at the first exec — shared read-only pages in the Toybox
  binary's BSS are COW-zeroed per-exec, so the new process *should* start clean.

  **Revised hypothesis (multi-core race):** Because the crashes appear mid-line and concurrent
  with another sh process, and because the fault address itself (`0x000000732a2e2a27`) decodes
  as the byte string `'*.*s\0\0\0` in little-endian — which looks like a shell glob token — the
  corruption may arise from a **Toybox sh tokeniser or glob-expansion buffer** that spills into
  the BSS region containing the passwd struct. This would be a memory-safety bug in Toybox's sh
  applet state rather than in the NOFORK dispatch itself. Exact identification requires
  cross-referencing BSS+`0x1058` with Toybox 0.8.14 symbol tables (not available in the stripped
  binary).

  **What has been verified:**
  - All 6 crash instances in one run share the same `epc=0x31312`, `ra=0x33950`, `a0=0x719f0`.
  - The fault address is always outside the valid sv39 userspace range (> `0x3fffffffffff`).
  - Crasher PIDs are `comm: sh` (Toybox sh processes, not an external command).
  - Tests that immediately surround a crash still exit with correct pass/fail status.
  - The init loop uses `/bin/sh "$t"` (full path → always fork+exec, never NOFORK) so each
    test's sh exits with the true exit code; the crash is in a concurrent subprocess, not in
    the test's own sh.
  - Three consecutive `make hw-test` runs all showed the same crash pattern (PIDs differ
    but addresses and epc are identical), confirming reproducibility.
  - The serial count inconsistency bug (38/42/72 TEST PASS counts in 3 runs) was a **separate
    issue** — pre-anchor contamination from a prior boot cycle in the capture file — **resolved**
    by the `tail -n +"$UBOOT_LINE"` trim added to `lib/board.sh` (PR #48).

  **How to reproduce:**
  ```sh
  # Build and deploy vf2config to the board's TFTP directory
  make hw-deploy BOARD_CONFIG=vf2config BOARD_ARCH=riscv NO_FETCH=1

  # Capture serial output; hardware auto-resets via USB relay
  make hw-test BOARD_TTY=/dev/ttyUSB0

  # Inspect the capture file:
  grep "unhandled signal 11" build/vf2config-riscv/dmesg.txt
  # Expect: several lines matching:
  #   sh[NNN]: unhandled signal 11 code 0x1 at 0x000000732a2e2[a2]727 in toybox[...]
  ```
  The crashes appear reliably within the first ~7 s of test execution, before the 43-test suite
  completes (~10 s total). All tests pass despite the crashes.

  **What's next / potential fixes:**

  1. **Add `/etc/passwd` to the initramfs** (minimal single-line root entry).
     `setup_env` reads `/etc/passwd` to populate HOME/SHELL/USER/LOGNAME. With the file absent,
     Toybox falls back to the zero-initialised BSS struct. If the BSS struct is ever corrupted,
     a real `/etc/passwd` entry would provide a valid pointer from the heap/rodata instead.
     This is low-risk and may eliminate the crash without touching any test logic.
     ```sh
     # Add to lib/initramfs.sh, just before "Pack cpio + gzip":
     printf 'root:x:0:0:root:/root:/bin/sh\n' > "$STAGE/etc/passwd"
     mkdir -p "$STAGE/etc"
     ```

  2. **Upgrade Toybox** beyond 0.8.14 and check if the crash disappears.
     The `TOYBOX_VERSION` pin in the Makefile currently locks to `0.8.14`. The upstream Toybox
     project may have fixed BSS aliasing between applet state and the passwd struct.

  3. **Identify the overlapping BSS symbol** using Toybox 0.8.14 source.
     BSS base `0xcaa90` + `0x1058` = VMA `0xcbae8`. With a debug build (`-g`) of Toybox 0.8.14
     for riscv64, `nm toybox | awk '$1 == "0xcbae8"'` (or nearby) would name the conflicting
     field. That would confirm whether this is a known alignment/layout bug.

  4. **Accept as won't-fix** if 1 and 2 don't pan out.
     The crashes are in throwaway subprocesses; all test outcomes remain correct.
     No harness change is required to maintain accurate test reporting.
