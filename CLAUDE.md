# CLAUDE.md — kernel-test

## Project purpose

This repo is a Bash-based harness for testing Linux release-candidate (-rc) kernels.
It builds kernels under multiple config profiles, boots them in QEMU/KVM with a minimal
Toybox initramfs, runs tests inside the VM, and writes a local HTML/text report.
The goal is systematic community verification of each -rc kernel.

## Tech stack

- **Entry point:** `Makefile` — all commands are invoked via `make <target> [VAR=value]`
- **Language:** Bash for all lib scripts — no Python, no Ruby, no extra runtimes
- **Virtualization:** QEMU/KVM (`qemu-system-x86_64`, `qemu-system-i386`); TCG for arm64 (`qemu-system-aarch64`) and riscv (`qemu-system-riscv64`)
- **Userland:** Toybox static binary (prebuilt, downloaded by `make bootstrap`) packed into a cpio initramfs; arch mapping: `x86_64` → `toybox-x86_64`, `i386` → `toybox-i686`, `arm64` → `toybox-aarch64`, `riscv` → `toybox-riscv64`; version pinned via `TOYBOX_VERSION` (default `0.8.14`)
- **Build cache:** ccache (always enabled; cache dir is `cache/`, gitignored)
- **Architectures:** `x86_64`, `i386`, `arm64`, and `riscv` (all four default; canonical list is `ARCHS_ALL` in the Makefile); arm64 and riscv use TCG (no KVM on x86 host); requires `aarch64-linux-gnu-gcc` + `qemu-system-aarch64` for arm64, `riscv64-linux-gnu-gcc` + `qemu-system-riscv64` for riscv (installed by `make bootstrap`)
- **Host tools:** `ccache`, `lzop` (kernel LZO compression), `bc`, `flex`, `bison`, `libelf`, `pahole`, `clang`, `lld`, `llvm` (all three required for `LLVM=1`: `clang`=compiler, `lld`=linker, `llvm`=tools like `llvm-ar`/`llvm-nm` — `clang` does not pull in `llvm` on Arch or Debian) — all installed by `make bootstrap`
- **Kernel configs:** `defconfig`, `tinyconfig`, `allnoconfig`, `kunitconfig`, `kunitrandconfig`, `allmodconfig`, `randconfig`, `rand500config`, `randdefconfig`; plus `localconfig` (not in default `CONFIGS`)
  - Bootable (build + VM test): `defconfig`, `tinyconfig`, `allnoconfig`, `kunitconfig`, `kunitrandconfig`, `rand500config`, `randdefconfig`, `localconfig`
  - Build-only (no VM boot): `allmodconfig` (boot impractical: sanitizers + built-in self-tests take 100+ s, modules not in initramfs), `randconfig` (unpredictable boot)
  - `kunitconfig` — uses `defconfig` as base + `configs/kunitconfig.config` fragment (CONFIG_KUNIT + core test suites); not a kernel make target, special-cased in `build.sh`; KUnit emits KTAP to serial console; `vm.sh` strips ANSI color codes then parses `ok`/`not ok` lines and records KUNIT_PASS/KUNIT_FAIL in vm.status; report shows `kunit:N/N` in Tests column
  - `kunitrandconfig` — uses `defconfig` as base; enumerates every `CONFIG_*KUNIT*=y` option from a fresh `randconfig` in a temp dir (exposing the full available set for this arch), appends them all to the defconfig base, applies `configs/kunitrandconfig.config` fragment (re-pins `CONFIG_KUNIT=y` + core suites), runs `olddefconfig` which drops any test module with unmet deps — only valid, buildable options survive; random set varies per run (rebuild required each time); saves `kunitrand-sampled.config` into `build/<config>-<arch>/`
  - `rand500config` — special: uses `tinyconfig` as base, samples 500 `=y` lines from a constrained `randconfig` generated in a temp dir (heavy subsystems, sanitizers, torture tests, non-gzip kernel compression excluded), applies the bootability fragment last; saves `rand-source.config` and `rand-sampled.config` into `build/<config>-<arch>/`
  - `randdefconfig` — uses `defconfig` as base, randomly disables 300 `=[ym]` options, applies a fragment that forces heavy subsystems off and re-pins bootability options including `CONFIG_KERNEL_GZIP=y` (prevents a non-standard compressor being auto-selected if GZIP is disabled); stays reliably under 5 minutes
  - `localconfig` — uses `/proc/config.gz` (running Manjaro kernel) as base + `configs/localconfig.config` fragment; for daily-driver builds; `make install` deploys to `/boot` via mkinitcpio + GRUB; x86_64 only
  - `randconfig` is constrained by `configs/randconfig.config` (disables modules + 5 heaviest subsystems + sanitizers + torture tests + non-gzip kernel compression) and subject to `BUILD_TIMEOUT` (default 1800 s); exits with `STATUS=TIMEOUT` if exceeded
  - Config fragments: `configs/<profile>.config` (arch-neutral base: PRINTK, TTY, INITRD, BINFMT, TMPFS) + optional `configs/<profile>-<arch>.config` (arch overlay: serial driver, FPU); both appended to `.config` and resolved with one `olddefconfig` pass; absent overlay is silently skipped; `localconfig` has no overlay (x86_64-only)

## Key files

| File | Role |
|---|---|
| `Makefile` | Main entry point; defines all targets and variables; calls lib scripts |
| `lib/bootstrap.sh` | Install all build/test dependencies (distro-aware: pacman/apt/dnf/zypper); safe to run as root (Ansible) or regular user — `SUDO` is auto-detected (`""` when root, `"sudo"` otherwise); on Debian/Ubuntu adds `${CODENAME}-backports` for `dwarves ≥1.25` (BTF) and `qemu-system-misc` (riscv64 QEMU); includes `lzop` for LZO kernel compression; installs `clang lld llvm` (all three required: `clang`=compiler, `lld`=linker, `llvm`=tools like `llvm-ar`/`llvm-nm` — `clang` does not pull in `llvm` on Arch or Debian); sanity checks `clang` and `llvm-ar`; REQUIRED tool check: `clang` and `llvm-ar` always checked; cross-compilers and QEMU binaries only checked for requested ARCHS; pahole version check warns if `<1.25`; downloads Toybox static binaries; activates git hooks |
| `lib/fetch.sh` | Fetch the latest kernel tag and write `build/.kernel-version`; mainline rc mode (default) or stable release mode (`STABLE_RELEASE=X.Y`); uses `git ls-remote` to discover the latest tag without transferring objects, then fetches only that tag with `--depth=1`; falls back to local tags when `ls-remote` fails (e.g. transient TLS error on hetzner-staging) |
| `lib/fetch-stable-rc.sh` | Fetch stable-rc branch tip (`STABLE_RC_BRANCH`), reset HEAD, read version from kernel Makefile, write `build/.kernel-version`; used by `make fetch-stable-rc` |
| `lib/fetch-next.sh` | Fetch linux-next `origin/master`, reset HEAD, write `build/.kernel-version`; requires `LINUX_NEXT=1` (set by `presets/kernel-test-next.mk`); used by `make fetch-next` |
| `presets/kernel-test-next.mk` | linux-next preset: sets `KERNEL_TREE=~/git/linux-next`, `LABEL=next`, `LINUX_NEXT:=1`; auto-loaded when clone dir is `kernel-test-next`; causes `make fetch` to error and redirects to `make fetch-next` |
| `lib/checkout.sh` | Fetch and checkout a specific tag or commit; verifies kernel Makefile version |
| `lib/build.sh` | Kernel build with ccache; out-of-tree `O=build/<config>-<arch>/`; derives `CROSS_COMPILE` and `KERNEL_IMAGE_NAME` (bzImage or Image) from arch; prints kernel tag/commit/remote at start; stores `KERNEL_TREE=` in every `build.status` write; deletes `vm.status` at start of each build so a failed build never shows stale test results in the report; `localconfig` is x86_64-only; when `SEED_CONFIG` is set (by `make replay`), copies the archived `.config` and runs `olddefconfig` instead of the normal config-target step; boot baseline (`BOOT_BASELINE_OPTS`) is a flat array of 7 arch-neutral options (PRINTK, TTY, INITRD, RD_GZIP, BINFMT_ELF, BINFMT_SCRIPT, TMPFS); arch-specific serial/FPU are owned by the arch overlay files (`configs/<profile>-<arch>.config`) and not in the safety net; auto-corrects if olddefconfig silently dropped any baseline option |
| `lib/initramfs.sh` | Assemble Toybox cpio initramfs; inject test scripts; arch mapping: `x86_64`→`toybox-x86_64`, `i386`→`toybox-i686`, `arm64`→`toybox-aarch64`, `riscv`→`toybox-riscv64`; cross-arch binaries (arm64, riscv) cannot execute on the x86_64 build host — falls back to `toybox-x86_64` for the applet list (applet set is identical across arches for the same Toybox version) |
| `lib/download-toybox.sh` | Download a single Toybox static binary for a given arch to `cache/`; idempotent (skips if already present); called by `lib/bootstrap.sh` once per arch |
| `lib/vm.sh` | Launch QEMU, capture serial console output, detect boot success/oops; arch-specific machine/CPU/console/image-path (x86: q35/ttyS0/bzImage; arm64: virt/cortex-a57/ttyAMA0/Image; riscv: virt/ttyS0/Image); KVM skipped for arm64 and riscv (TCG only on x86 host); x86_64 and i386 also use `VM_TIMEOUT=TIMEOUT×2` when KVM is absent (TCG mode, e.g. Hetzner — `/dev/kvm` unreadable); arm64 and riscv always use `VM_TIMEOUT=TIMEOUT×2` and 1 G RAM (TCG is slower; arm64/riscv COW fork OOMs in 512 M); earlycon is arch-specific: x86/i386 use `earlycon=uart8250,io,0x3f8` (explicit COM1 ISA address — bare `earlycon` silently breaks console when `CONFIG_SERIAL_EARLYCON=y` but `CONFIG_ACPI=n`); arm64 and riscv use bare `earlycon` (auto-detected from QEMU DT); extracts `FAILED_TESTS` into `vm.status`; strips ANSI color codes from dmesg and counts KUnit KTAP `ok`/`not ok` lines into `KUNIT_PASS`/`KUNIT_FAIL`; prints each failed name on its own `WARN` line under the PARTIAL message |
| `lib/report.sh` | Collate results; write `summary.html`, `summary.txt`, and `summary.mail.txt`; report dir named `<label>-<major.minor>-<datetime>-<version>` (e.g. `mainline-7.2-2026-07-14_10-00-00-v7.2-rc2`); label auto-derived from STABLE_RELEASE/KERNEL_TREE/KERNEL_VERSION or set via `LABEL=`; `summary.txt` opens with an LKML-ready preamble (Subject, Label, build status, repo/commit, host, tested arches, Tested-by) followed by the full results table; `summary.mail.txt` contains only the preamble lines; `summary.html` shows an Overall pass/fail badge and a linked file-list section; config MISMATCH sets `OVERALL=FAIL`; `FAILED_TESTS` from `vm.status` appears in the Notes column (text: `failed: name1, name2`; HTML: red-highlighted); copies `vm.status` to report dir as `vmstatus-<config>-<arch>.txt`; auto-diffs vs previous run of the same label and vs pinned baseline at end; calls `lib/warnings.sh` at the end (warning extraction, informational only); exits with code 1 when `OVERALL=FAIL` |
| `lib/diff.sh` | Compare two report dirs for per-test regressions/fixes; reads `vmstatus-<config>-<arch>.txt`; called automatically by `report.sh` and via `make diff`; auto-detect (no args) restricts to same label as newest run; handles both old (`YYYY-MM-DD_HH-MM-SS_version`) and new (`label-X.Y-YYYY-MM-DD_HH-MM-SS-version`) dir formats; `make baseline` pins a reference run; exits 1 when regressions found |
| `scripts/migrate-reports.sh` | Rename old-format report dirs to new label-prefixed format; dry-run by default; pass `--apply` to rename; guesses label from version string (rc → mainline, vX.Y.Z → stable); auto-updates `baseline` symlink when its target is renamed |
| `scripts/kconfig-check.sh` | Static analysis: scan a subsystem for missing Kconfig `select` dependencies; Pass 1 (`#ifdef CONFIG_X`-guarded struct fields in headers, high signal) always runs; Pass 2 (`IS_ENABLED(CONFIG_X)` calls in drivers, high false-positive rate) is opt-in via `PASS2=1`; subsystem gate symbol (`CONFIG_<SUBSYSTEM>`) skipped in both passes — all drivers implicitly depend on it; `VERIFY=1` builds each candidate object to confirm; `DRIVER=` restricts to one file; `ARCH=` selects build arch; `SKIP_CFGS=CONFIG_X,CONFIG_Y` skips symbols as missing-select candidates; `GATE_CFGS=CONFIG_X` enables symbols in `verify_build` so drivers inside `if SYMBOL endif` blocks appear in `.config` after `olddefconfig`; logs to `build/kconfig-check-<ARCH>/<SYM>/<CFG>/`; run via `make kconfig-check SUBSYSTEM=<name>` |
| `scripts/kconfig-enumerate.sh` | Enumerate all `config`/`menuconfig` entries from a subsystem Kconfig file; recursively follows `source` directives; skips paths with variable references (`$(SRCARCH)` etc.); outputs `CONFIG_<NAME>` per line, sorted and deduplicated; used by `scripts/build-kconfig.sh` |
| `scripts/build-kconfig.sh` | Exhaustive per-option build+boot sweep for a kernel subsystem; enumerates all config entries via `kconfig-enumerate.sh`, generates one `.config` per entry (tinyconfig + `randkconfigconfig.config` base + `randkconfigconfig-<arch>.config` arch overlay + that single option), builds and boots each through the full pipeline via `lib/build.sh` + `lib/vm.sh`; caches tinyconfig base per arch; uses `arch_cross_compile` from `lib/common.sh`; `DRY_RUN=1` prints the full list without building; `DRIVER=<stem>` restricts sweep to a single driver (accepts `.c` suffix); `GATE_CFGS=` enables extra symbols for drivers inside nested `if` blocks; run via `make kconfig-build SUBSYSTEM=<name> [DRY_RUN=1] [DRIVER=<stem>] [GATE_CFGS=CONFIG_X]` |
| `scripts/config-archive.sh` | Scan all `reports/*/` and populate `configs/archive_passed/` + `configs/archive_failed/`; deduplicates by SHA256 (passed wins); names: `kconfig-<config>-<arch>-<version>-<sha256>.config` (passed) / `kconfig-<config>-<arch>-<version>-<sha256>-<STAGE-SYMPTOM>.config` (failed); run via `make config-archive`; generates `index.txt` and `index.html` for each archive; failed index includes one-line detail per row (`    -> detail` in txt; `title=` tooltip in html) extracted from report-dir files at scan time — silent fallback when report dir absent |
| `scripts/consolidate-index.sh` | Merge per-source failure indexes into a unified cross-machine view; reads `consolidation/<source>/archive_failed/index.txt` for each source dir present; deduplicates by (source, SHA256); sorts by version then config; writes `consolidation/index.txt` + `consolidation/index.html` with SOURCE column prepended; detail lines embedded as `title=` tooltip on failure reason cell; SOURCE cell links to per-source `archive_failed/index.html`; handles zero sources gracefully; `consolidation/` is gitignored — all data stays local; run via `make consolidate-index` |
| `consolidation/` | Gitignored local directory; populated manually by copying `archive_failed/index.txt` from each clone/machine into `consolidation/<source>/archive_failed/index.txt`; source labels: `local-mainline`, `local-stable`, `local-stable-rc`, `local-next`, `hetzner-mainline`, `hetzner-stable`, `hetzner-stable-rc`, `hetzner-next` |
| `scripts/config-bisect.sh` | Binary-search a failing archived config to find the responsible option(s); extracts candidates (archived − tinyconfig+bootability baseline); baseline is tinyconfig + `rand500config.config` + `rand500config-<arch>.config` arch overlay so serial/FPU options are never candidates; verifies baseline passes and full config fails, then splits candidates by halves until one suspect remains; single-option verification confirms it; uses `arch_cross_compile` and `apply_arch_overlay` from `lib/common.sh`; `PINNED_OPTS=CONFIG_X,CONFIG_Y` (comma- or space-separated) injects options into every test step but not the baseline — enables multi-pass interaction bisect; `DRY_RUN=1` shows candidate list and time estimate; auto-archives minimal reproducer with `-bisect-from-<sha>` suffix (only one level stripped — chaining prevented); artifacts in `bisect/<timestamp>-<config>-<arch>-<sha256>/` (gitignored); run via `make bisect CONFIG_FILE=<path>` |
| `scripts/canary-patch.sh` | Patch `KERNEL_TREE/drivers/misc/` with built-in diagnostic modules; copies `modules/*/` sources, adds `obj-$(CONFIG_*)` entries to `drivers/misc/Makefile`, inserts Kconfig stanzas; idempotent; run once before `make all CANARY=1`; run via `make canary-patch` |
| `scripts/verify-patch.sh` | Build one or more kernel source files (`FILES=`) with GCC and Clang across `VERIFY_ARCHS` (default: all four); optional before/after comparison against a base git commit (`BASE=<ref>`) using a temporary git worktree; prints a summary table and writes per-combo logs to `build/verify-patch/logs-<timestamp>/`; exits 1 on any failure or regression; run via `make verify-patch FILES=... [BASE=...] [COMPILER=gcc\|clang\|both]` |
| `docs/verify-patch-plan.md` | Design doc for `make verify-patch`: usage examples, variable reference, before/after mode, compiler handling table, output format, exit codes |
| `docs/patch-quality-workflow.md` | Pre-send quality gate (own patches) + maintainer-style reviewer workflow (patches from others); verification checklists: problem statement, root cause, build/runtime verification, format; `make verify-patch` integration; Tested-by reply format |
| `docs/upstream-patch-workflow.md` | Step-by-step authoring workflow: identify failure → root cause → design doc branch → reproducer → apply fix → commit format → checkpatch → send-email → track; reference for commit message format and mailing lists |
| `modules/boot_canary/boot_canary.c` | Raw UART boot canary: `early_initcall()` writes `[BOOT_CANARY]` directly to the UART (x86: COM1 I/O port `0x3f8`; arm64: PL011 MMIO `ioremap(0x09000000)`), bypassing printk; must be built-in (`CONFIG_BOOT_CANARY=y`); diagnoses silent boots by distinguishing "kernel ran but no console" from "kernel never reached early_initcall" |
| `modules/boot_canary/Makefile` | Out-of-tree Makefile for standalone compile-testing of `boot_canary.c` against a running kernel's headers; produces a `.ko` (loadable module) for syntax/type checking only — the canary must be built-in (`=y`) to have effect; not used by the harness |
| `modules/boot_canary/README.md` | Documents why `early_initcall()` in a `.ko` is dead code, how to patch the kernel tree, and arch-specific UART notes |
| `modules/debug_42/debug_42.c` | Creates `/proc/debug_42` returning `"42\n"` at `module_init` time; confirms procfs and VFS are functional after boot; exercised by `tests/custom/250_debug-42.sh`; must be built-in (`CONFIG_DEBUG_42=y`) via `make canary-patch` + `CANARY=1` |
| `modules/debug_42/Makefile` | Out-of-tree Makefile for standalone compile-testing of `debug_42.c`; same caveat as `boot_canary/Makefile` — produces `.ko` for syntax check only |
| `configs/canary.config` | Config fragment for `CANARY=1` mode: sets `CONFIG_BOOT_CANARY=y`, `CONFIG_PROC_FS=y` (required by `debug_42`; disabled in tinyconfig), and `CONFIG_DEBUG_42=y`; appended by `lib/build.sh` when `CANARY=1` |
| `configs/archive_passed/` | Config archive in `DATA_REPO`; one `.config` per unique SHA256 that ever produced a PASS result (build or boot+test); gitignored in the harness repo |
| `configs/archive_failed/` | Config archive in `DATA_REPO`; one `.config` per unique SHA256 that only ever failed; filename encodes failure: `BUILD_FAIL`, `BUILD_TIMEOUT`, `BOOT_FAIL-kernel-panic`, `BOOT_FAIL-oops`, `BOOT_FAIL-timeout`, `BOOT_FAIL-no-test-done`, `TEST_FAIL-N-of-M`, `KUNIT_FAIL-N-of-M`; gitignored in the harness repo |
| `scripts/init-data-repo.sh` | One-time data repo initialisation: `git init`, creates `reports/`, `configs/archive_passed/`, `configs/archive_failed/`, `consolidation/` dirs, sets `.gitignore`, makes an initial commit; run via `make init-data-repo`; prefer `make bootstrap` on machines that already have a clone |
| `docs/data-repo-plan.md` | Design doc for the data repo split: scope table, `DATA_REPO` variable, directory layout, bootstrap behaviour, per-run auto-commit flow, `FINDINGS.md` split, migration steps, multi-machine sync, verification checklist |
| `lib/common.sh` | Shared helpers: `log`/`info`/`warn`/`die`, `require_env`, `is_build_only`, `read_kernel_makefile_version`; fetch helpers: `setup_git_array`, `reset_to_fetch_head`, `write_kernel_version`; arch helpers: `arch_cross_compile <arch>` (prints `aarch64-linux-gnu-` / `riscv64-linux-gnu-` / `""` for native), `arch_kernel_image <arch>` (prints `bzImage` for x86, `Image` for arm64/riscv), `arch_toybox_name <arch>` (maps kernel arch → Toybox binary suffix: x86_64→x86_64, i386→i686, arm64→aarch64, riscv→riscv64; used by `download-toybox.sh` and `initramfs.sh`), `apply_arch_overlay <dot_config> <configs_dir> <profile> <arch>` (silently appends `<profile>-<arch>.config` if present) |
| `lib/warnings.sh` | Extract compiler warnings from `build/<config>-<arch>/build.log` for all PASS builds; strip absolute build-dir prefix; write per-combo `warnings-<config>-<arch>.txt` + `warnings-summary.txt` (counts table, NEW SINCE PREV RUN, CROSS-ARCH DIVERGENCE vs x86_64 baseline) + `warnings-diff-prev.txt` to report dir; auto-diffs vs `reports/warnings-baseline` symlink when set; called automatically by `report.sh` and standalone via `make warnings`; informational only (no OVERALL impact) |
| `lib/dmesg.sh` | Capture host kernel dmesg (`make dmesg [DMESG_LABEL=mainline]`); analyse errors/firmware bugs/hardware subsystems (NVMe, Wi-Fi, AMD, NVIDIA/ideapad); diff warning/error lines vs previous capture for same label; writes `DATA_REPO/dmesg/<name>.txt` + `DATA_REPO/dmesg/<name>-analysis.txt`; exits 1 on VERDICT=ERRORS |
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
| `tests/custom/250_debug-42.sh` | Reads `/proc/debug_42` and verifies it returns `"42"`; skips gracefully when `CONFIG_DEBUG_42` not built in (CANARY=1 not used); confirms procfs + VFS operational |
| `tests/custom/260_vfs-links.sh` | VFS path resolution: symlink create/readlink/dangling, hard link write-visible-through-alias, FIFO mkfifo + type check + open/close via `exec 3<>` (O_RDWR, no fork); fires on all bootable configs |
| `tests/custom/270_proc-sys-vm.sh` | `/proc/sys/vm` range validation: overcommit_memory∈{0,1,2}, swappiness 0–200, dirty_ratio/dirty_background_ratio 1–100; `/proc/buddyinfo` + `/proc/zoneinfo` sanity; skips when procfs absent |
| `tests/custom/280_proc-self-extended.sh` | `/proc/self/fd` (stdin/stdout/stderr present), `fdinfo/1` (pos/flags), `limits` (Max open files/processes), `io` (read_bytes/write_bytes, skipped when CONFIG_TASK_IO_ACCOUNTING off); skips when procfs absent |
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
| `configs/<profile>-<arch>.config` | Arch overlay for one profile+arch pair; appended after the base fragment, resolved in the same `olddefconfig` pass; arch names match `$ARCH`: `x86_64`, `i386`, `arm64`, `riscv`; absent overlay is silently skipped; `localconfig` has no overlay (x86_64-only, 8250 stays in its base) |
| `configs/localconfig.config` | Hardware fragment for Lenovo AMD Ryzen 7 5800H (NVMe, MT7921 WiFi, BT, AMD_PMC, AES-NI, BTRFS); applied on top of `/proc/config.gz` |
| `docs/config-bisect-plan.md` | Design doc for `make bisect`: algorithm, step directory structure, decision table, usage examples |
| `docs/boot-canary-plan.md` | Design doc for `make canary-patch` + `CANARY=1`: problem statement, two-tier diagnostic approach, architecture notes, decision table, harness integration |
| `docs/linux-next-workflow.md` | linux-next workflow: clone setup, daily `make fetch-next`, full suite, replay archived configs, patch preparation and submission (commit message format, `checkpatch --strict`, `get_maintainer.pl` routing rules, `git send-email`) |
| `docs/stable-rc-workflow.md` | Stable-rc (rolling branch) workflow: clone setup, `STABLE_RC_BRANCH` update cadence, `make fetch-stable-rc`, `make all` |
| `docs/consolidation-workflow.md` | Cross-machine failure consolidation: source labels, per-clone `make config-archive`, `scp index.txt` from Hetzner, `make consolidate-index`, reading the HTML output and deciding which issue to investigate next |
| `docs/debian-support-plan.md` | Debian bookworm support: root/sudo auto-detection (`EUID=0` → no sudo), apt backports with priority-100 pin (prevents auto-upgrade of cross-compilers), arch-gated REQUIRED check, pahole version check; Hetzner-staging deployment notes (TCG timing, systemd timer pattern) |
| `docs/warnings-analysis-plan.md` | Design doc for `make warnings`: extraction scope, cross-arch divergence (x86_64 baseline), per-combo files, between-run diff, baseline pin, output format |
| `docs/ci-lint-test-plan.md` | Design doc for Tier 1 (`make lint`) + Tier 2 (`make ci-test`) CI: check table, test scope, fixture structure, GitHub Actions workflow layout, files changed |
| `scripts/ci-lint.sh` | Tier 1 lint checks: `bash -n` on all .sh, shellcheck bash-mode on harness scripts, shellcheck sh-mode on Toybox test scripts, memory file size ≤ 150 lines, test-inventory coverage, design doc on feat/*/fix/* branches, PR title format (CI-only via `$GITHUB_EVENT_PATH`); run via `make lint`; all checks run even on failure — reports all errors at once |
| `scripts/ci-run-tests.sh` | Tier 2 test runner: discovers and runs `tests/ci/test-*.sh` in sorted order, aggregates pass/fail counts, exits 1 with list of failed scripts; run via `make ci-test` |
| `tests/ci/lib.sh` | Shared test harness for Tier 2: `begin_test`, `pass`, `fail`, `finish`; `tmpdir` (sets `$_LAST_TMPDIR`, tracks for cleanup); `setup_data_repo` (git-init temp DATA_REPO, sets+exports `DATA_REPO`/`REPORT_DIR`); `setup_kernel_tree` (git-init temp kernel tree with version Makefile, sets+exports `KERNEL_TREE`); `setup_git_stub` (fake git that no-ops pull/push, passes rest through); assert helpers: `assert_eq`, `assert_ne`, `assert_contains`, `assert_not_contains`, `assert_file_exists`, `assert_exit0`, `assert_exit1`; NOTE: always call `tmpdir`, `setup_data_repo`, `setup_kernel_tree`, `setup_git_stub` WITHOUT `$()` — they export variables that `$()` subshell isolation would hide |
| `tests/ci/test-common.sh` | Tests `lib/common.sh`: `arch_cross_compile`, `arch_kernel_image`, `arch_toybox_name`, `apply_arch_overlay`, `read_kernel_makefile_version` |
| `tests/ci/test-config-archive.sh` | Tests `scripts/config-archive.sh`: PASS→archive_passed, FAIL→archive_failed, dedup (passed wins), index files written |
| `tests/ci/test-config-bisect.sh` | Tests `scripts/config-bisect.sh` pure-logic: filename parsing, candidate extraction (no kernel build) |
| `tests/ci/test-consolidate-index.sh` | Tests `scripts/consolidate-index.sh`: 2-source merge, dedup, zero sources, HTML SOURCE column |
| `tests/ci/test-diff.sh` | Tests `lib/diff.sh`: regression/fix detection, exit codes, output file |
| `tests/ci/test-makefile-defaults.sh` | Tests Makefile variable defaults: ARCHS_ALL, CONFIGS, DATA_REPO, REPORT_DIR, TIMEOUT, BUILD_TIMEOUT, BUILD_ONLY_CONFIGS |
| `tests/ci/test-migrate-reports.sh` | Tests `scripts/migrate-reports.sh`: dry-run, --apply rename, new-format skip, baseline symlink update |
| `tests/ci/test-report.sh` | Tests `lib/report.sh`: OVERALL=PASS/FAIL logic, summary.txt structure, auto-commit to DATA_REPO |
| `tests/ci/fixtures/` | Static fixtures for Tier 2 tests: two report dirs (rc1 all-pass, rc2 tinyconfig-FAIL), consolidation source indexes with overlapping SHA entries |
| `.github/workflows/ci.yml` | GitHub Actions: `lint` job (every push/PR); `detect-changes` job (paths filter: `lib/**`, `scripts/**`, `tests/ci/**`, `Makefile`); `ci-test` job (only when tier2=true); concurrency cancel-in-progress |

## Conventions

- `lib/` contains the **core pipeline** scripts (fetch, build, initramfs, vm, report, diff, install, dmesg, checkout, common.sh); `scripts/` contains **on-demand tools** invoked explicitly (kconfig-check, kconfig-enumerate, build-kconfig, config-archive, config-bisect, canary-patch, migrate-reports); both directories use the same Bash conventions; the distinction is semantic, not about who calls them
- Git hooks are in `.githooks/`; activate with `make hooks` (or automatically via `make bootstrap`); `pre-commit` checks staged files (shellcheck, executable bit, artifact guard, inventory sync); `commit-msg` enforces conventional commit format; `pre-push` sweeps all tracked files (shellcheck, executable bit, inventory coverage, design doc, memory sizes, `awk` ban in VM tests)
- All scripts use `#!/bin/bash` and `set -euo pipefail`
- Functions are lowercase_snake_case
- Constants are UPPER_SNAKE_CASE; the Makefile exports them into the environment before invoking lib scripts
- Makefile variables (`KERNEL_TREE`, `STABLE_KERNEL_TREE`, `STABLE_RELEASE`, `TAG`, `DATA_REPO`, `NO_FETCH`, `NO_BUILD`, `ARCHS_ALL`, `ARCHS`, `CONFIGS`, `TIMEOUT`, `BUILD_TIMEOUT`, `GCC`, `REPORT_DIR`, `V`, `TOYBOX_VERSION`, `CONFIG_FILE`, `SEED_CONFIG`, `SUBSYSTEM`, `DRIVER`, `VERIFY`, `DRY_RUN`, `GATE_CFGS`, `PINNED_OPTS`, `FILES`, `BASE`, `COMPILER`, `VERIFY_ARCHS`, `CLEAN`) are the public API; `DATA_REPO` defaults to `$(HOME)/git/kernel-test-data` and is tilde-expanded/absolutified like `KERNEL_TREE`; `REPORT_DIR` defaults to `$(DATA_REPO)/reports`; set identically in all preset files; override per-machine via `local.mk`; `GCC` defaults to `gcc` — set `GCC=gcc-15` for stable kernels that predate GCC 16; `TOYBOX_VERSION` defaults to `0.8.14`; `NO_BUILD=1` skips the kernel build step and reuses existing `build/<config>-<arch>/` artifacts; `CONFIG_FILE=<path>` is the archive path passed to `make replay` and `make bisect`; `SEED_CONFIG` is set automatically by `make replay` and inherited by `lib/build.sh` to bypass the normal config-target step; `SUBSYSTEM=` required by `kconfig-check` and `kconfig-build`; `DRIVER=` restricts both tools to a single driver (`.c` suffix accepted); `VERIFY=1` triggers object build confirmation in `kconfig-check`; `DRY_RUN=1` prints the candidate list and time estimate without building in `make bisect`, and prints the full option list without building in `kconfig-build`; `GATE_CFGS=CONFIG_X,CONFIG_Y` enables extra gate symbols in both kconfig tools; `PINNED_OPTS=CONFIG_X,CONFIG_Y` (comma- or space-separated) injects options into every bisect test step but not the baseline — used for multi-pass interaction bisect; `CANARY=1` injects `CONFIG_BOOT_CANARY=y` + `CONFIG_DEBUG_42=y` via `configs/canary.config` — requires prior `make canary-patch` to patch the kernel tree; `FILES=` required by `make verify-patch` — space-separated `.o` files or directories to build; `BASE=<git-ref>` enables before/after comparison in `make verify-patch` via git worktree; `COMPILER=gcc|clang|both` selects compilers for `make verify-patch` (default: `both`); `VERIFY_ARCHS` defaults to `$(ARCHS)` so passing `ARCHS=x86_64` to `make verify-patch` works as expected; set `VERIFY_ARCHS=` explicitly to override independently of the main pipeline; `CLEAN=1` forces a clean rebuild of each per-combo build directory in `make verify-patch` (default: `0`)
- `presets/<dir>.mk` — committed preset auto-included by the Makefile based on `$(notdir $(CURDIR))`; `presets/kernel-test.mk` sets only `DATA_REPO` (local mainline clone named `kernel-test`); `presets/kernel-test-mainline.mk` sets `KERNEL_TREE`, `LABEL`, `DATA_REPO` (Hetzner clone named `kernel-test-mainline`); `presets/kernel-test-stable.mk` sets `STABLE_RELEASE ?= 7.1`; `presets/kernel-test-stable-rc.mk` sets `KERNEL_TREE`, `LABEL`, `GCC`, `BUILD_TIMEOUT`, `STABLE_RC_BRANCH`; `presets/kernel-test-next.mk` sets `KERNEL_TREE`, `LABEL`, `LINUX_NEXT := 1`; all preset files set `DATA_REPO ?= $(HOME)/git/kernel-test-data`
- `local.mk` — gitignored; included after the preset for machine-local overrides (e.g. different paths); do not commit
- `STABLE_RC_BRANCH` — branch name used by `make fetch-stable-rc` (e.g. `linux-7.1.y`); set in `presets/kernel-test-stable-rc.mk`; update this when the stable series bumps (e.g. 7.1.y → 7.2.y); see `docs/stable-rc-workflow.md`
- `BUILD_TIMEOUT` (default 1800 s) wraps only the `bzImage` build step via `timeout`; exit 124 → `STATUS=TIMEOUT` in `build.status`; defconfig/kunitconfig x86_64 takes ~10–12 min on a 16-core machine
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

1. Create `tests/custom/NNN_my-test.sh` where `NNN` is a 3-digit number (e.g. `290_my-test.sh`)
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
| Add or remove a `tests/ci/test-*.sh` file | `CLAUDE.md` Key files table (new/remove row) |
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
