# CLAUDE.md — kernel-test

## Project purpose

This repo is a Bash-based harness for testing Linux release-candidate (-rc) kernels.
It builds kernels under multiple config profiles, boots them in QEMU/KVM with a minimal
Toybox initramfs, runs tests inside the VM, and writes a local HTML/text report.
The goal is systematic community verification of each -rc kernel.

## Tech stack

- **Entry point:** `Makefile` — all commands are invoked via `make <target> [VAR=value]`
- **Language:** Bash for all lib scripts — no Python, no Ruby, no extra runtimes
- **Virtualization:** QEMU/KVM (`qemu-system-x86_64`, `qemu-system-i386`); TCG for arm64 (`qemu-system-aarch64`)
- **Userland:** Toybox static binary (prebuilt, downloaded by `make bootstrap`) packed into a cpio initramfs; arch mapping: `x86_64` → `toybox-x86_64`, `i386` → `toybox-i686`, `arm64` → `toybox-aarch64`; version pinned via `TOYBOX_VERSION` (default `0.8.9`)
- **Build cache:** ccache (always enabled; cache dir is `cache/`, gitignored)
- **Architectures:** `x86_64`, `i386`, and `arm64` (all three default); arm64 uses TCG (no KVM on x86 host); requires `aarch64-linux-gnu-gcc` + `qemu-system-aarch64` (installed by `make bootstrap`)
- **Host tools:** `ccache`, `lzop` (kernel LZO compression), `bc`, `flex`, `bison`, `libelf`, `pahole` — all installed by `make bootstrap`
- **Kernel configs:** `defconfig`, `tinyconfig`, `allnoconfig`, `kunitconfig`, `kunitrandconfig`, `allmodconfig`, `randconfig`, `rand500config`, `randdefconfig`; plus `localconfig` (not in default `CONFIGS`)
  - Bootable (build + VM test): `defconfig`, `tinyconfig`, `allnoconfig`, `kunitconfig`, `rand500config`, `randdefconfig`, `localconfig`
  - Build-only (no VM boot): `allmodconfig` (boot impractical: sanitizers + built-in self-tests take 100+ s, modules not in initramfs), `randconfig` (unpredictable boot), `kunitrandconfig` (random KUnit module set; use `kunitconfig` for deterministic KUnit testing)
  - `kunitconfig` — uses `defconfig` as base + `configs/kunitconfig.config` fragment (CONFIG_KUNIT + core test suites); not a kernel make target, special-cased in `build.sh`; KUnit emits KTAP to serial console; `vm.sh` strips ANSI color codes then parses `ok`/`not ok` lines and records KUNIT_PASS/KUNIT_FAIL in vm.status; report shows `kunit:N/N` in Tests column
  - `kunitrandconfig` — uses `defconfig` as base; enumerates every `CONFIG_*KUNIT*=y` option from a fresh `randconfig` in a temp dir (exposing the full available set for this arch), appends them all to the defconfig base, applies `configs/kunitrandconfig.config` fragment (re-pins `CONFIG_KUNIT=y` + core suites), runs `olddefconfig` which drops any test module with unmet deps — only valid, buildable options survive; random set varies per run (rebuild required each time); saves `kunitrand-sampled.config` into `build/<config>-<arch>/`
  - `rand500config` — special: uses `tinyconfig` as base, samples 500 `=y` lines from a constrained `randconfig` generated in a temp dir (heavy subsystems, sanitizers, torture tests, non-gzip kernel compression excluded), applies the bootability fragment last; saves `rand-source.config` and `rand-sampled.config` into `build/<config>-<arch>/`
  - `randdefconfig` — uses `defconfig` as base, randomly disables 300 `=[ym]` options, applies a fragment that forces heavy subsystems off and re-pins bootability options including `CONFIG_KERNEL_GZIP=y` (prevents a non-standard compressor being auto-selected if GZIP is disabled); stays reliably under 5 minutes
  - `localconfig` — uses `/proc/config.gz` (running Manjaro kernel) as base + `configs/localconfig.config` fragment; for daily-driver builds; `make install` deploys to `/boot` via mkinitcpio + GRUB; x86_64 only
  - `randconfig` is constrained by `configs/randconfig.config` (disables modules + 5 heaviest subsystems + sanitizers + torture tests + non-gzip kernel compression) and subject to `BUILD_TIMEOUT` (default 1200 s); exits with `STATUS=TIMEOUT` if exceeded
  - Config fragments in `configs/<profile>.config` are appended post-config and resolved via `olddefconfig`; used to re-enable the minimum options (TTY, serial, initramfs, BINFMT_ELF/SCRIPT) that stripped configs disable

## Key files

| File | Role |
|---|---|
| `Makefile` | Main entry point; defines all targets and variables; calls lib scripts |
| `lib/bootstrap.sh` | Install all build/test dependencies (distro-aware: pacman/apt/dnf/zypper); includes `lzop` for LZO kernel compression; downloads Toybox static binaries; activates git hooks |
| `lib/fetch.sh` | `git fetch` + auto-checkout; mainline rc mode (default) or stable release mode (`STABLE_RELEASE=X.Y`) |
| `lib/fetch-stable-rc.sh` | Fetch stable-rc branch tip (`STABLE_RC_BRANCH`), reset HEAD, read version from kernel Makefile, write `build/.kernel-version`; used by `make fetch-stable-rc` |
| `lib/fetch-next.sh` | Fetch linux-next `origin/master`, reset HEAD, write `build/.kernel-version`; requires `LINUX_NEXT=1` (set by `presets/kernel-test-next.mk`); used by `make fetch-next` |
| `presets/kernel-test-next.mk` | linux-next preset: sets `KERNEL_TREE=~/git/linux-next`, `LABEL=next`, `LINUX_NEXT:=1`; auto-loaded when clone dir is `kernel-test-next`; causes `make fetch` to error and redirects to `make fetch-next` |
| `lib/checkout.sh` | Fetch and checkout a specific tag or commit; verifies kernel Makefile version |
| `lib/build.sh` | Kernel build with ccache; out-of-tree `O=build/<config>-<arch>/`; derives `CROSS_COMPILE` and `KERNEL_IMAGE_NAME` (bzImage or Image) from arch; prints kernel tag/commit/remote at start; stores `KERNEL_TREE=` in every `build.status` write; deletes `vm.status` at start of each build so a failed build never shows stale test results in the report; `localconfig` is x86_64-only; when `SEED_CONFIG` is set (by `make replay`), copies the archived `.config` and runs `olddefconfig` instead of the normal config-target step |
| `lib/initramfs.sh` | Assemble Toybox cpio initramfs; inject test scripts; downloads prebuilt `toybox-{x86_64,i686,aarch64}` to `cache/` |
| `lib/vm.sh` | Launch QEMU, capture serial console output, detect boot success/oops; arch-specific machine/CPU/console/image-path (x86: q35/ttyS0/bzImage; arm64: virt/cortex-a57/ttyAMA0/Image); KVM skipped for arm64 (TCG only on x86 host); arm64 uses `VM_TIMEOUT=TIMEOUT×2` and 1 G RAM (TCG is slower; arm64 COW fork OOMs in 512 M); earlycon is arch-specific: x86/i386 use `earlycon=uart8250,io,0x3f8` (explicit COM1 ISA address — bare `earlycon` silently breaks console when `CONFIG_SERIAL_EARLYCON=y` but `CONFIG_ACPI=n`); arm64 uses bare `earlycon` (auto-detected from QEMU DT); extracts `FAILED_TESTS` into `vm.status`; strips ANSI color codes from dmesg and counts KUnit KTAP `ok`/`not ok` lines into `KUNIT_PASS`/`KUNIT_FAIL`; prints each failed name on its own `WARN` line under the PARTIAL message |
| `lib/report.sh` | Collate results; write `summary.html`, `summary.txt`, and `summary.mail.txt`; report dir named `<label>-<major.minor>-<datetime>-<version>` (e.g. `mainline-7.2-2026-07-14_10-00-00-v7.2-rc2`); label auto-derived from STABLE_RELEASE/KERNEL_TREE/KERNEL_VERSION or set via `LABEL=`; `summary.txt` opens with an LKML-ready preamble (Subject, Label, build status, repo/commit, host, tested arches, Tested-by) followed by the full results table; `summary.mail.txt` contains only the preamble lines; `summary.html` shows an Overall pass/fail badge and a linked file-list section; config MISMATCH sets `OVERALL=FAIL`; `FAILED_TESTS` from `vm.status` appears in the Notes column (text: `failed: name1, name2`; HTML: red-highlighted); copies `vm.status` to report dir as `vmstatus-<config>-<arch>.txt`; auto-diffs vs previous run of the same label and vs pinned baseline at end; exits with code 1 when `OVERALL=FAIL` |
| `lib/diff.sh` | Compare two report dirs for per-test regressions/fixes; reads `vmstatus-<config>-<arch>.txt`; called automatically by `report.sh` and via `make diff`; auto-detect (no args) restricts to same label as newest run; handles both old (`YYYY-MM-DD_HH-MM-SS_version`) and new (`label-X.Y-YYYY-MM-DD_HH-MM-SS-version`) dir formats; `make baseline` pins a reference run; exits 1 when regressions found |
| `scripts/migrate-reports.sh` | Rename old-format report dirs to new label-prefixed format; dry-run by default; pass `--apply` to rename; guesses label from version string (rc → mainline, vX.Y.Z → stable); auto-updates `baseline` symlink when its target is renamed |
| `scripts/kconfig-check.sh` | Static analysis: scan a subsystem for missing Kconfig `select` dependencies; Pass 1 (`#ifdef CONFIG_X`-guarded struct fields in headers, high signal) always runs; Pass 2 (`IS_ENABLED(CONFIG_X)` calls in drivers, high false-positive rate) is opt-in via `PASS2=1`; subsystem gate symbol (`CONFIG_<SUBSYSTEM>`) skipped in both passes — all drivers implicitly depend on it; `VERIFY=1` builds each candidate object to confirm; `DRIVER=` restricts to one file; `ARCH=` selects build arch; `SKIP_CFGS=CONFIG_X,CONFIG_Y` skips symbols as missing-select candidates; `GATE_CFGS=CONFIG_X` enables symbols in `verify_build` so drivers inside `if SYMBOL endif` blocks appear in `.config` after `olddefconfig`; logs to `build/kconfig-check-<ARCH>/<SYM>/<CFG>/`; run via `make kconfig-check SUBSYSTEM=<name>` |
| `scripts/kconfig-build.sh` | Full-image build for a single driver to confirm a Kconfig fix end-to-end; complements `kconfig-check VERIFY=1` (which builds only the driver object); accepts `GATE_CFGS=CONFIG_X,CONFIG_Y` to enable gate symbols; `DRIVER=` accepts `.c` suffix; logs to `build/kconfig-build-<ARCH>/<SYM>/`; run via `make kconfig-build SUBSYSTEM=<name> DRIVER=<stem>` |
| `scripts/kconfig-enumerate.sh` | Enumerate all `config`/`menuconfig` entries from a subsystem Kconfig file; recursively follows `source` directives; skips paths with variable references (`$(SRCARCH)` etc.); outputs `CONFIG_<NAME>` per line, sorted and deduplicated; used by `lib/build-kconfig.sh` |
| `lib/build-kconfig.sh` | Exhaustive per-option build+boot sweep for a kernel subsystem; enumerates all config entries via `kconfig-enumerate.sh`, generates one `.config` per entry (tinyconfig + `randkconfigconfig.config` bootability fragment + that single option), builds and boots each through the full pipeline via `lib/build.sh` + `lib/vm.sh`; caches tinyconfig base per arch; `DRY_RUN=1` prints the full list without building; `DRIVER=<stem>` restricts sweep to a single driver (accepts `.c` suffix); `GATE_CFGS=` enables extra symbols for drivers inside nested `if` blocks; run via `make kconfig-build SUBSYSTEM=<name> [DRY_RUN=1] [DRIVER=<stem>] [GATE_CFGS=CONFIG_X]` |
| `scripts/config-archive.sh` | Scan all `reports/*/` and populate `configs/archive_passed/` + `configs/archive_failed/`; deduplicates by SHA256 (passed wins); names: `kconfig-<config>-<arch>-<version>-<sha256>.config` (passed) / `kconfig-<config>-<arch>-<version>-<sha256>-<STAGE-SYMPTOM>.config` (failed); run via `make config-archive`; generates `index.txt` and `index.html` for each archive; failed index includes one-line detail per row (`    -> detail` in txt; `title=` tooltip in html) extracted from report-dir files at scan time — silent fallback when report dir absent |
| `configs/archive_passed/` | Committed config archive: one `.config` per unique SHA256 that ever produced a PASS result (build or boot+test) |
| `configs/archive_failed/` | Committed config archive: one `.config` per unique SHA256 that only ever failed; filename encodes failure: `BUILD_FAIL`, `BUILD_TIMEOUT`, `BOOT_FAIL-kernel-panic`, `BOOT_FAIL-oops`, `BOOT_FAIL-timeout`, `BOOT_FAIL-no-test-done`, `TEST_FAIL-N-of-M`, `KUNIT_FAIL-N-of-M` |
| `lib/common.sh` | Shared helpers: `log`/`info`/`warn`/`die`, `require_env`, `is_build_only`, `read_kernel_makefile_version`; fetch helpers: `setup_git_array`, `reset_to_fetch_head`, `write_kernel_version` |
| `lib/dmesg.sh` | Capture host kernel dmesg (`make dmesg [DMESG_LABEL=mainline]`); analyse errors/firmware bugs/hardware subsystems (NVMe, Wi-Fi, AMD, NVIDIA/ideapad); diff warning/error lines vs previous capture for same label; writes `dmesg/<name>.txt` + `dmesg/<name>-analysis.txt`; exits 1 on VERDICT=ERRORS |
| `tests/001_smoke.sh` | Minimal boot smoke: shell arithmetic, `/dev/null`, `/proc/version`, `/sys` |
| `tests/custom/001_print-dmesg.sh` | Full dmesg dump to serial console — runs early so kernel messages appear before other tests; always passes |
| `tests/custom/010_check-proc.sh` | `/proc` content: cpuinfo, meminfo, uptime, cmdline, filesystems |
| `tests/custom/020_check-sysfs.sh` | `/sys` hierarchy: kernel, block, class presence |
| `tests/custom/030_check-dmesg.sh` | dmesg output: kernel version string, no early oops/panic |
| `tests/custom/040_check-devnodes.sh` | `/dev` nodes: null, zero, console, urandom presence |
| `tests/custom/050_check-kernel.sh` | Kernel version format, UTS fields, `/proc/sys/kernel` |
| `tests/custom/060_check-tmpfs.sh` | tmpfs write/read round-trip |
| `tests/custom/070_check-proc-interrupts.sh` | `/proc/interrupts` readable and non-empty |
| `tests/custom/080_check-slabinfo.sh` | `/proc/slabinfo` readable (CONFIG_SLUB_DEBUG) |
| `tests/custom/090_check-clocksource.sh` | Active clocksource registered in dmesg |
| `tests/custom/100_network-loopback.sh` | Bring up `lo`, ping `127.0.0.1` (CONFIG_NET + CONFIG_INET) |
| `tests/custom/110_tmpfs-stress.sh` | 1 MiB write/read/verify + 20-file inode allocation on tmpfs |
| `tests/custom/120_rng.sh` | `/dev/urandom` read at 512 B and 4096 B (CRNG output path) |
| `tests/custom/130_fork-exec.sh` | fork/exec, exit-code propagation, 20 sequential forks, SIGCHLD |
| `tests/custom/140_sysctl.sh` | `/proc/sys` read + write/restore of `kernel.hostname`, `pid_max`, etc. |
| `tests/custom/150_mmap.sh` | VMA table via `/proc/self/maps`: readable, count > 2, `[stack]` present, anonymous mappings, fork/exec stability; `/proc/meminfo` AnonPages/PageTables |
| `tests/custom/160_signal.sh` | Signal delivery: `kill -0` process-existence, SIGTERM/SIGKILL/SIGUSR1 via `/bin/kill` + poll, `/proc/self/status` SigBlk/SigIgn/SigCgt mask fields |
| `tests/custom/170_pipe.sh` | Pipe I/O: basic data flow, 3-process pipeline, exit-code propagation, 1 MiB large transfer, 10 sequential writes |
| `tests/custom/180_timer.sh` | Timer/clock subsystem: `/proc/uptime` readable and advancing, epoch sanity via `date +%s`, `sleep 0` nanosleep, `/proc/timer_list` hrtimer infrastructure |
| `tests/custom/190_scheduler.sh` | CFS scheduler: `/proc/loadavg` format, `nice -n 10` and `nice -n -5` (setpriority syscall), `/proc/self/status` context switch counters, `/proc/schedstat` per-CPU stats |
| `tests/custom/200_inotify.sh` | inotify subsystem: `/proc/sys/fs/inotify` limit knobs (max_queued_events, max_user_instances, max_user_watches) |
| `tests/custom/210_futex.sh` | Futex: `/proc/sys/kernel/futex_private_hash_size` (kernel 6.x+, CONFIG_FUTEX); `/proc/sys/kernel/sem` |
| `tests/custom/220_proc-net.sh` | /proc/net: `/proc/net/dev` interface table, `/proc/net/sockstat` socket counters, `/proc/net/protocols` |
| `tests/custom/230_bind-mount.sh` | Bind mounts: `mount --bind` on initramfs rootfs dirs, alias file visibility, `/proc/mounts` entry, umount cleanup |
| `tests/custom/240_cgroups.sh` | cgroups v2: `/sys/fs/cgroup/cgroup.controllers`, `cgroup.procs`, `cgroup.subtree_control` |
| `.githooks/pre-commit` | Pre-commit hook: shellcheck on staged `.sh` files; executable bit on staged test scripts; guard against staged build artifacts; new test script → `memory/test-inventory.md` must also be staged |
| `.githooks/commit-msg` | Commit-msg hook: enforces conventional commit format `<type>[(<scope>)]: <desc>` |
| `.githooks/pre-push` | Pre-push hook: shellcheck on all tracked `.sh` files; executable bit on all test scripts; test-inventory coverage; design doc required on `feat/*`/`fix/*` branches; memory file sizes (≤ 150 lines); `awk` banned in VM test scripts |
| `lib/install.sh` | Install built kernel to `/boot` (Arch/Manjaro): reads `KERNEL_TREE` from `build.status` (no need to re-specify `STABLE_RELEASE` at install time); runs `olddefconfig` to resolve config drift non-interactively when kernel version changes; refreshes `CONFIG_SHA256` in `build.status` after `olddefconfig`; warns if no `vm.status` exists (kernel untested) or if last VM boot was not PASS; modules, vmlinuz, custom mkinitcpio conf (`MODULES=()`, system hooks preserved), preset, `dkms autoinstall` (out-of-tree modules e.g. nvidia/vbox), mkinitcpio, grub-mkconfig |
| `tests/hardware/verify.sh` | Real-hardware verification for localconfig: NVMe, MT7921 WiFi, BT, AMD_PMC, K10TEMP, IDEAPAD_LAPTOP, AES-NI, BTRFS, exFAT; run on the booted laptop |
| `configs/kunitconfig.config` | KUnit framework + core test suites (lib/, mm/ SLUB); applied on defconfig base |
| `configs/kunitrandconfig.config` | KUnit=y + core suites baseline; applied after random KUNIT module enumeration; olddefconfig drops modules with unmet deps |
| `configs/rand500config.config` | Bootability fragment for rand500config (TTY, serial, initramfs); applied last so it wins over any conflicting random selection |
| `configs/randdefconfig.config` | Heavy subsystem force-off + bootability fragment for randdefconfig; pins `CONFIG_KERNEL_GZIP=y` so a non-standard compressor is not auto-selected if GZIP is randomly disabled |
| `configs/randconfig.config` | Constraint fragment for randconfig and rand500config sampling pool: MODULE=n, heavy subsystems off, sanitizers off, RCU/lock torture tests off, KUNIT=n, non-gzip kernel compression off |
| `configs/randkconfigconfig.config` | Bootability fragment for `kconfig-build` exhaustive sweeps (TTY, serial, initramfs); applied to tinyconfig base before enabling the option under test; identical content to `rand500config.config` |
| `configs/localconfig.config` | Hardware fragment for Lenovo AMD Ryzen 7 5800H (NVMe, MT7921 WiFi, BT, AMD_PMC, AES-NI, BTRFS); applied on top of `/proc/config.gz` |
| `docs/linux-next-workflow.md` | linux-next workflow: clone setup, daily `make fetch-next`, full suite, replay archived configs, patch preparation and submission (commit message format, `checkpatch --strict`, `get_maintainer.pl` routing rules, `git send-email`) |
| `docs/stable-rc-workflow.md` | Stable-rc (rolling branch) workflow: clone setup, `STABLE_RC_BRANCH` update cadence, `make fetch-stable-rc`, `make all` |

## Conventions

- Git hooks are in `.githooks/`; activate with `make hooks` (or automatically via `make bootstrap`); `pre-commit` checks staged files (shellcheck, executable bit, artifact guard, inventory sync); `commit-msg` enforces conventional commit format; `pre-push` sweeps all tracked files (shellcheck, executable bit, inventory coverage, design doc, memory sizes, `awk` ban in VM tests)
- All scripts use `#!/bin/bash` and `set -euo pipefail`
- Functions are lowercase_snake_case
- Constants are UPPER_SNAKE_CASE; the Makefile exports them into the environment before invoking lib scripts
- Makefile variables (`KERNEL_TREE`, `STABLE_KERNEL_TREE`, `STABLE_RELEASE`, `TAG`, `NO_FETCH`, `NO_BUILD`, `ARCHS`, `CONFIGS`, `TIMEOUT`, `BUILD_TIMEOUT`, `GCC`, `REPORT_DIR`, `V`, `TOYBOX_VERSION`, `CONFIG_FILE`, `SEED_CONFIG`, `SUBSYSTEM`, `DRIVER`, `VERIFY`, `DRY_RUN`, `GATE_CFGS`) are the public API; `GCC` defaults to `gcc` — set `GCC=gcc-15` for stable kernels that predate GCC 16; `TOYBOX_VERSION` defaults to `0.8.9`; `NO_BUILD=1` skips the kernel build step and reuses existing `build/<config>-<arch>/` artifacts; `CONFIG_FILE=<path>` is the archive path passed to `make replay`; `SEED_CONFIG` is set automatically by `make replay` and inherited by `lib/build.sh` to bypass the normal config-target step; `SUBSYSTEM=` required by `kconfig-check` and `kconfig-build`; `DRIVER=` restricts both tools to a single driver (`.c` suffix accepted); `VERIFY=1` triggers object build confirmation in `kconfig-check`; `DRY_RUN=1` prints the full option list without building in `kconfig-build`; `GATE_CFGS=CONFIG_X,CONFIG_Y` enables extra gate symbols in both kconfig tools
- `presets/<dir>.mk` — committed preset auto-included by the Makefile based on `$(notdir $(CURDIR))`; `presets/kernel-test-stable.mk` sets `STABLE_RELEASE ?= 7.1`; `presets/kernel-test-stable-rc.mk` sets `KERNEL_TREE`, `LABEL`, `GCC`, `BUILD_TIMEOUT`, `STABLE_RC_BRANCH`; `presets/kernel-test-next.mk` sets `KERNEL_TREE`, `LABEL`, `LINUX_NEXT := 1`; mainline has no preset (uses Makefile defaults)
- `local.mk` — gitignored; included after the preset for machine-local overrides (e.g. different paths); do not commit
- `STABLE_RC_BRANCH` — branch name used by `make fetch-stable-rc` (e.g. `linux-7.1.y`); set in `presets/kernel-test-stable-rc.mk`; update this when the stable series bumps (e.g. 7.1.y → 7.2.y); see `docs/stable-rc-workflow.md`
- `BUILD_TIMEOUT` (default 1200 s) wraps only the `bzImage` build step via `timeout`; exit 124 → `STATUS=TIMEOUT` in `build.status`; defconfig/kunitconfig x86_64 takes ~10–12 min on a 16-core machine
- `make all` always runs `report` even when build or test fails; the overall exit code still reflects failures — use `make all NO_FETCH=1 ...` rather than chaining `build initramfs test report` individually (chaining stops at the first failure)
- `make test` skips any config whose `build.status` is not `STATUS=PASS` (prints `SKIP (build TIMEOUT/FAIL)`) so partial build failures don't block testing of the configs that did build
- `KERNEL_TREE` is normalized at parse time: leading `~` is expanded and the path is made absolute via `$(abspath ...)`; pass `~/git/linux` or `../linux` freely
- When `STABLE_RELEASE` is set, `KERNEL_TREE` is overridden to `STABLE_KERNEL_TREE` (default: `~/git/linux-stable`) before normalization — all downstream scripts (build, test, report) automatically use the stable tree
- Lib scripts are invoked as subprocesses by the Makefile (not sourced), so they must not rely on shell state from each other
- VM serial output is captured live to `build/<config>-<arch>/dmesg.txt` and copied to `reports/<date>_<time>_<version>/dmesg-<config>-<arch>.txt` by the report step
- Test output protocol inside the VM: `/init` emits `> TEST RUN: <name>` before each script and `< TEST PASS: <name>` / `< TEST FAIL: <name>` after; `vm.sh` counts those markers for TESTS_PASS/TESTS_FAIL
- Report `OVERALL` is `FAIL` when any build status is non-PASS, any boot fails, any shell test fails (`TESTS_FAIL > 0`), any KUnit test fails (`KUNIT_FAIL > 0`), or any config fingerprint check shows `MISMATCH`; `report.sh` exits 1 when `OVERALL=FAIL` so `make` and CI detect the failure
- KUnit KTAP output: `vm.sh` detects `KTAP version` or `# Subtest:` in dmesg, strips ANSI color codes (`\e[Nm`) and `\r` from the file, then counts `ok`/`not ok` lines; results stored as KUNIT_PASS/KUNIT_FAIL in vm.status; count includes suite summary lines (one per suite) which are few and correctly reflect suite pass/fail state; report shows `kunit:N/N` in Tests column
- Exit codes: `0` = pass, `1` = test failure, `2` = infrastructure/build error
- Never write to the kernel source tree; all build artifacts go under `build/`
- `build.status` stores `KERNEL_TREE=<absolute-path>` at build time; `install.sh` reads it back so `make install` always uses the correct tree without re-specifying `STABLE_RELEASE` or `KERNEL_TREE`
- Run `make clean` when switching between kernel trees (mainline ↔ stable); generated headers in `build/` are tied to the tree they were built from — reusing them across trees causes subtle mismatches (e.g. `ucs_width_table.h` format differs between mainline and stable 7.1.x)

## How to add a test

1. Create `tests/custom/NNN_my-test.sh` where `NNN` is a 3-digit number (e.g. `250_my-test.sh`)
   — tests run in filename-sort order; leave gaps (010, 020, …) so new tests can be inserted
2. Exit 0 = pass, non-zero = fail; use `ok: msg` / `FAIL: msg` / `skip: msg` for assertion output
3. The harness copies all `tests/custom/*.sh` into the initramfs and runs them in the VM
4. Serial output: `/init` wraps each test with `> TEST RUN: NNN_my-test` and `< TEST PASS/FAIL: NNN_my-test`
5. `vm.sh` counts `< TEST PASS:` / `< TEST FAIL:` lines; counts feed the report table and OVERALL result

## How to add a new config profile

Pass the profile name via the `CONFIGS` variable on the command line, or add it to
the default value of `CONFIGS` in the `Makefile`. Optionally place a config fragment
in `configs/<profile>.config`; if present, it is appended to `.config` after the
kernel config target runs and `make olddefconfig` resolves dependencies. If absent,
the kernel config target's output is used as-is.

## Branch workflow

All changes go through a pull request — no direct commits to `main`.

**Branch naming** — `<type>/<kebab-description>`:
- `feat/190-scheduler-test`
- `fix/180-timer-i386-sleep`
- `docs/update-readme-clone-url`
- `chore/branch-workflow`

**Commit messages** — conventional commits, enforced by `.githooks/commit-msg`:
```
<type>[(<scope>)]: <description>
```
Types: `feat` `fix` `docs` `refactor` `chore` `ci` `test` `style` `perf`

**Merging strategy** — always **merge commits** (GitHub "Create a merge commit"):
- Never squash or rebase; the branch history is the record of how the work evolved
- PR title = the merge commit subject, so it must also follow conventional commit format
- Branch protection on `main`: PRs required, force-push disabled

**PR checklist** (in `.github/PULL_REQUEST_TEMPLATE.md`):
- What changed (one sentence)
- Type checkbox
- Test run checkbox (`make all NO_FETCH=1` on affected configs)
- Toybox sh pitfalls acknowledged

**Before opening a PR**, at minimum run:
```sh
make all NO_FETCH=1 CONFIGS=tinyconfig
```
For any change touching `tests/`, run the full suite:
```sh
make all NO_FETCH=1
```

## Memory file update triggers

Keep `memory/*.md` in sync with the code. The pre-push hook enforces coverage for test
scripts; the table below covers everything else.

| When you… | Update these memory files |
|---|---|
| Add a test script | `memory/test-inventory.md` (new row in table, update next slot) · `memory/project.md` (test count + directory listing) · `CLAUDE.md` Key files table (new row) |
| Remove a test script | `memory/test-inventory.md` (remove row) · `memory/project.md` (test count) · `CLAUDE.md` Key files table (remove row) |
| Add or remove a config profile | `memory/config-profiles.md` · `memory/project.md` (profile count) |
| Change a Makefile variable (default, name, purpose) | `memory/workflows.md` |
| Change build, fetch, or test pipeline behaviour | `memory/workflows.md` · `memory/project.md` |
| Discover a new Toybox sh bug or workaround | `memory/code-quality.md` (Toybox pitfalls list) |
| Change a git hook or quality gate | `memory/code-quality.md` (hooks table) |
| Change architecture or fundamental design | `memory/project.md` |

The pre-push hook enforces:
- Every `tests/custom/*.sh` and `tests/001_smoke.sh` name must appear in `memory/test-inventory.md`
- Every `memory/*.md` (except `MEMORY.md`) must be ≤ 150 lines
- No `awk` calls in VM test scripts (`tests/custom/*.sh`, `tests/001_smoke.sh`) — `awk` is not in the prebuilt Toybox binary; use `grep | cut` instead

The pre-commit hook enforces:
- When a new test script is staged, `memory/test-inventory.md` must also be staged

## What NOT to do

- Do not introduce Python, Go, or any non-shell dependency without explicit user approval
- Do not require root for the build steps; only QEMU may need it (use KVM group membership)
- Do not hardcode paths — use `KERNEL_TREE`, `BUILD_DIR`, `REPORT_DIR` variables
- Do not commit build artifacts, ccache, or reports — all are gitignored
- Do not commit directly to `main` — always open a PR from a feature branch

## Fetching kernels

`make fetch` auto-dispatches based on the preset variables loaded for the current clone:

| Clone directory | Preset sets | `make fetch` does |
|---|---|---|
| `kernel-test` | _(nothing)_ | `git ls-remote` → `fetch --depth=1 v*-rc*` tag |
| `kernel-test-stable` | `STABLE_RELEASE=7.1` | `git ls-remote` → `fetch --depth=1 vX.Y.*` tag |
| `kernel-test-stable-rc` | `STABLE_RC_BRANCH=linux-7.1.y` | `git fetch origin linux-7.1.y` + `git reset --hard FETCH_HEAD` |
| `kernel-test-next` | `LINUX_NEXT=1`, `KERNEL_TREE=~/git/linux-next` | **error** — use `make fetch-next` instead |

`kernel-test-next` uses `make fetch-next` (not `make fetch`) because linux-next has no rc tags:
```sh
make fetch-next   # git fetch origin master + git reset --hard FETCH_HEAD
```

`make fetch-stable`, `make fetch-stable-rc`, and `make fetch-next` remain as explicit override
targets for use outside the preset-managed clones.

**Stable-rc note** — announcements like `v7.1.4-rc2` are **not git tags**; they are the tip
of the rolling `linux-7.1.y` branch. `STABLE_RC_BRANCH` is set in
`presets/kernel-test-stable-rc.mk`; update it when the series bumps. See
`docs/stable-rc-workflow.md`.

**Pin a specific version:**
```sh
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux        # mainline
make checkout TAG=v7.1.3 STABLE_RELEASE=7.1               # stable
```

**Skip fetch entirely:**
```sh
make all NO_FETCH=1
```

## Running locally

```sh
# Same workflow in all four clones — preset handles the differences
make fetch                                    # fetch the right kernel for this clone (mainline/stable/stable-rc)
make fetch-next                               # fetch linux-next master (kernel-test-next clone only)
make smoke                                    # quick sanity: kunitconfig + tinyconfig, all archs
make full                                     # broader: 5 bootable configs, all archs
make all NO_FETCH=1                           # full pipeline: all 9 configs + archs

# Daily-driver build + install (all three clones)
make local                                    # build localconfig x86_64, no timeout
make install CONFIGS=localconfig ARCHS=x86_64 # deploy to /boot (needs sudo)

# Show what is currently checked out
make info

# Pin a specific stable version, then test
make checkout TAG=v7.1.3 STABLE_RELEASE=7.1
make all NO_FETCH=1

# Partial run — single config and arch
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64

# Fast iteration on test scripts — skip kernel rebuild, repack initramfs and re-run
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig

# Test rand500config only (tinyconfig + 500 random options, bootable)
make all NO_FETCH=1 CONFIGS=rand500config ARCHS=x86_64
```

Always use `make all NO_FETCH=1` (not `make build initramfs test report`) — `all` guarantees
the report is written even when build or test steps fail; individual target chaining stops at
the first failure.

All output goes to stdout; the final report path is printed by the `report` target.
