# Project — kernel-test

## Purpose

Reproducible harness for verifying Linux release-candidate (-rc) and stable kernels.
Builds under multiple config profiles, boots in QEMU/KVM, runs functional tests inside
the VM, and produces a local HTML + plain-text report suitable for LKML submission.
Goal: systematic community verification of each -rc kernel.

## Architecture

```
make all
  └─ lib/fetch.sh / lib/fetch-stable-rc.sh   auto-dispatch by preset: mainline rc tag / stable vX.Y.* tag / stable-rc branch tip
  └─ lib/build.sh        cross-compile kernel per (config × arch), ccache; clears vm.status on start
  └─ lib/initramfs.sh    Toybox cpio initramfs per (config, arch); inject tests/custom/*.sh + ns-* binaries (tests/ns/) + perf-event + arena-test (tests/programs/); write capability markers (/tests/ns-enabled, perf-enabled, arena-enabled, watchdog-enabled)
  └─ lib/vm.sh           QEMU boot (KVM for x86, TCG for arm64), capture serial, count TEST PASS/FAIL + KUnit KTAP ok/not ok
  └─ lib/report.sh       aggregate status files → summary.html + summary.txt; copies vm.status; auto-diffs vs prev run + baseline; calls warnings.sh
  └─ lib/warnings.sh     extract ': warning:' lines from build logs (PASS builds only); per-combo files + summary (counts, NEW/FIXED since prev, cross-arch divergence vs x86_64); make warnings standalone
  └─ lib/diff.sh         compare two report dirs for per-test regressions/fixes; invoked by report.sh + make diff
  └─ lib/dmesg.sh        host-side only: capture + analyse running kernel dmesg; make dmesg [DMESG_LABEL=]
```

All user-facing commands go through `make`. Makefile exports env vars; lib scripts
are subprocesses (not sourced), so they carry no shell state between stages.

## Key Decisions

| Decision | Rationale |
|---|---|
| Bash only | No extra runtimes; any Linux box can run it |
| Toybox static binary | No package manager, no rootfs; just a cpio + the binary |
| Out-of-tree builds `O=build/<config>-<arch>/` | Isolates artifacts; enables parallel builds |
| ccache always on | 2–10× rebuild speedup; `cache/` is gitignored |
| `make all` always runs `report` | Even on build/test failure there is always an artifact |
| Config fragment via `cat >> .config + olddefconfig` | Reliable for all targets; `KCONFIG_ALLCONFIG` is overridden by `tinyconfig` internally |
| `BUILD_TIMEOUT` wraps only bzImage step | Prevents runaway builds; exit 124 = TIMEOUT |
| Sanitizers + non-gzip compressors excluded from randconfig constraints | KCOV/KASAN crash on tinyconfig base; lz4/zstd etc. may not be installed → exit 127; excluding prevents false failures; `lzop` is now installed by `make bootstrap` so LZO is no longer excluded |
| build.sh deletes vm.status at start | Failed builds never show stale test results from a prior run |
| CONFIG_SHA256 recomputed post-build | syncconfig can modify .config during make bzImage; hash stored after build reflects actual file |
| report.sh prefers kernel Makefile for version | git describe fails on untagged trees (stable-rc); read_kernel_makefile_version always authoritative |
| kunitrandconfig is build-only | Random KUnit module set; use kunitconfig for deterministic KUnit boot testing |
| preset auto-dispatch via $(notdir $(CURDIR)) | Same `make fetch` command works in mainline/stable/stable-rc clones; directory name selects presets/kernel-test-*.mk; `kernel-test-next` preset sets `LINUX_NEXT=1`, causing `make fetch` to error and redirect to `make fetch-next` |
| Per-(config,arch) initramfs | watchdog marker requires grepping per-build `.config` for `CONFIG_WATCHDOG=y`; one `initramfs-$CONFIG-$ARCH.cpio.gz` per pair → markers reflect actual config state; `build.status` prerequisite auto-rebuilds initramfs after kernel build |

## Current State (2026-08-16)

- **Architectures:** x86_64 + i386 + arm64 + riscv (all default); x86 uses KVM when `/dev/kvm` is accessible, falls back to TCG (2× timeout) on non-KVM hosts (e.g. Hetzner); arm64/riscv always use TCG (riscv requires `riscv64-linux-gnu-gcc`, `qemu-system-riscv64 ≥8.x` — bookworm-backports for QEMU B-extension support); arm64 QEMU uses `-cpu cortex-a57` (ARMv8.0-A) — LSE atomics (ARMv8.1-A mandatory) are absent from `/proc/cpuinfo Features`, which is expected, not a regression; Toybox mapping: x86_64→toybox-x86_64, i386→toybox-i686, arm64→toybox-aarch64, riscv→toybox-riscv64; Clang builds (`LLVM=1`) require `clang` + `lld` + `llvm` — all three packages installed by `make bootstrap` (clang does not pull in llvm on Arch or Debian)
- **Config profiles:** 9 default + 2 extra (localconfig x86_64-only; vf2config riscv-only JH7110 VisionFive 2); each uses two-layer fragments: arch-neutral base (`configs/<profile>.config`) + arch overlay (`configs/<profile>-<arch>.config` — serial driver, FPU; absent = silently skipped)
- **Tests:** 50 total (1 smoke + 49 custom; see test-inventory.md); next slot: 490_
- **dev-test (PR #56, open):** `make dev-test` — ≤5-min branch verification gate covering ≥50% of 35 decision paths. Fixed core (lint + C build + 4 CI tests + tinyconfig/defconfig/localconfig VM smokes) always runs; random draw (uniform LCG, SEED=N reproducible, BUDGET=N configurable, budget_ok() governs time) covers remaining paths. Environment-aware: board paths D4–D6 skipped with notice when HAS_BOARD=no. `make hook-dev-test` toggles opt-in pre-push block. Coverage map: `tests/ci/coverage-map.md`. LCG bug: `r=$(fn)` runs in subshell — always inline LCG arithmetic, never call via `$()`. perf-event.c: `sched_yield()` before `read()` fixes TASK_CLOCK returning 0 on `CONFIG_HIGH_RES_TIMERS=n`+`HZ=250`. test-fetch.sh: `STABLE_RELEASE=""` in `run_fetch()` prevents stable-clone preset propagating into fake test kernel tree. randconfig.config: `CONFIG_DEBUG_ATOMIC_SLEEP=n` prevents false `ISSUES=1` when a boot-path driver calls GFP_KERNEL in atomic context with certain random 500-option combinations. `CONFIG_DEBUG_PREEMPT=n` prevents false `ISSUES=1` from `BUG: using __this_cpu_read() in preemptible code` (gpio_winbond + rand500config/x86_64 v7.1.8 #6). snapshot.c: on any issue detected, prints each triggering dmesg line as `ISSUE_LINE:` field for in-snapshot diagnostics. Verified: 5/5 `make dev-test` PASS (68–74% coverage per run).
- **Current kernel (stable clone):** v7.1.8; tinynsconfig/x86_64 50/50 PASS (after perf-event fix above); tinyconfig/x86_64 + localconfig/x86_64 50/50 PASS.
- **Fetch strategy:** four clones (`kernel-test`, `kernel-test-stable`, `kernel-test-stable-rc`, `kernel-test-next`), each auto-loads preset by directory name; `make fetch` dispatches correctly in the first three; `kernel-test-next` uses `make fetch-next` (linux-next has no rc tags); `~/git/linux-next` is the kernel tree for `kernel-test-next`
- **Current kernel (mainline clone):** v7.2-rc6; `make smoke` PASS 43/43 all 8 combos (kunitconfig+tinyconfig × 4 archs, kunit 259/259 x86/arm64/i386 + 28/28 riscv); `make ns-smoke` PASS 43/43 all 8 combos (kunitnsconfig+tinynsconfig × 4 archs)
- **stable-rc clone (local):** v7.1.8-rc1; `make extended` 19/20 PASS (randdefconfig/arm64 timed out — stochastic: random disable of CONFIG_ARM64_4K_PAGES flips to 16K pages, silent QEMU hang; fixed in PR #46 by pinning 4K pages in configs/randdefconfig-arm64.config); all real config profiles PASS on all 4 archs; Tested-by sent to LKML for v7.1.8-rc1
- **randdefconfig arm64 page-size fix (PR #46, merged 2026-08-08):** `configs/randdefconfig-arm64.config` now pins `CONFIG_ARM64_4K_PAGES=y`; 16K/64K page kernels silently fail to boot on QEMU virt/cortex-a57
- **Hardware board testing (Phase 6a + 6b merged, PR #48 2026-08-09):** `lib/hw-bootstrap.sh` sets up host infra (networkd DHCPServer, atftpd TFTP, udev relay rule); `make hw-test` / `make hw` drive `lib/board.sh`. Features: U-Boot SPL anchor (Phase 1 waits for banner, Phase 2 anchors TEST_DONE after it); TFTP/PXE progress relayed to host; reboot detection with 50-line guard (distinguishes SPL→main from genuine reboot); `/etc/passwd`+`/etc/group` in initramfs (fixes Toybox sh SIGSEGV on SMP RISC-V — `getpwuid(0)` BSS aliasing); `dmesg -n 1` at top of `/init` (prevents deferred kernel printk from splitting `< TEST PASS:` mid-write — was causing 42/43 instead of 43/43); `stat -L` in relay same-device guard (symlink-safe); Phase 2 tail consolidation (one `tail_out` read per 0.5s iteration); `install_program_binary` helper in initramfs.sh. Verified: VisionFive 2 (JH7110 quad-core), v7.2-rc6, 5/5 consecutive runs → **43/43 PASS** each (~37–54s). Key quirks: Arch uses `uucp` serial group; relay may be CP210x (`10c4:ea60`) not CH340 (`1a86:7523`) — set in `local.mk`; atftpd requires `--user user.group` (no `nogroup` on Arch)
- **initramfs /init block-buffer fix (2026-08-16):** Toybox sh 0.8.11+ uses block-buffered stdout; `reboot -f` is a direct syscall that skips atexit, so `echo "TEST_DONE"` and trailing `TEST PASS` markers were silently dropped on VF2 hardware. Buffer also caused bursts of parent-echo output to appear out-of-order relative to child test output (garbled serial capture: test lines merged, snapshot output cut off by reboot message). Fix: all protocol markers in `/init` (`BOOT_OK`, `> TEST RUN:`, `< TEST PASS:`, `< TEST FAIL:`, summary, `TEST_DONE`) now use `printf '...\n' > /dev/console`, bypassing the block buffer. Verified: tinyconfig/x86_64 50/50 PASS, markers correctly ordered.
- **snapshot issue detection (PR #54, merged 2026-08-16):** Extended snapshot binary and 480_snapshot.sh with kernel health probing. DMESG field scans ring buffer for: oops/bugs/panics/rcu_stall/hung_task/oom_kill/lockup (soft+hard; no double-count with BUG:)/kunit_fail ("not ok N" with digit guard). TAINTED decodes all 20 bits (0–19); selective is_issue: MACHINE_CHECK/BAD_PAGE/DIE/WARN/SOFTLOCKUP count, OOT/TEST/FWCTL/proprietary do not. ISSUES: N field; exit 0=clean 1-254=issue-count 255=infra-fail. 480_snapshot.sh reads boot-time ISSUES from /tmp/snapshot.txt (not re-run — klogctl(KLOG_READ_ALL) is non-destructive; re-run accumulated ring-buffer messages from the test suite causing false positives). CI extended to 39 assertions. Verified: 50/50 PASS on tinyconfig/allnoconfig/defconfig/kunitconfig × x86_64; kunit_fail=0 with 259 "ok N" KUnit lines in ring buffer.
- **snapshot (PR #52, merged 2026-08-16):** 1 new test slot (480_) backed by `tests/programs/snapshot/snapshot.c`. Collects 27 fields at boot: identity (HOSTNAME/UNAME/INIT), system (UPTIME/LOADAVG/PAGESIZE/CLOCKSOURCE), memory (MEMORY/KERNELMEM/HUGEPAGES/SWAP), CPU (CPU model+cores/FLAGS), security (LSM/ASLR/DMESG_RESTRICT/KPTR_RESTRICT/TAINTED), kernel state (SCHEDSTATS/CGROUP_CTRL/ENTROPY/#MODULES/FS/DMESG/ISSUES/CMDLINE). DMESG field scans ring buffer for: oops/bugs/panics/rcu_stall/hung_task/oom_kill/lockup (soft+hard; no double-count with BUG:)/kunit_fail ("not ok N" with digit — avoids false matches). TAINTED decodes all 20 bits (0–19); selective is_issue: MACHINE_CHECK/BAD_PAGE/DIE/WARN/SOFTLOCKUP count, OOT/TEST/FWCTL/proprietary do not. ISSUES: N field; exit 0=clean 1-254=issue-count 255=infra-fail. 480_snapshot.sh reads boot-time ISSUES from /tmp/snapshot.txt (not re-run — klogctl(KLOG_READ_ALL) is non-destructive; re-run accumulates test-suite ring buffer messages). CI: tests/ci/test-snapshot.sh (39 assertions).
- **syscall-tests (PR #51, merged 2026-08-11):** 6 new test slots (420_–470_) backed by a single cross-compiled binary (`tests/programs/syscall-tests/`). Tests: 32-bit boundary (lseek64 >4 GiB + mmap), seccomp filter enforcement, io_uring NOP round-trip, timerfd/eventfd/signalfd, AF_UNIX socketpair, landlock enforcement. CI: `tests/ci/test-syscall-tests.sh` (14 assertions). Verified: defconfig PASS 49/49 × 4 arches on v7.2-rc7 mainline + v7.1.7 stable. Deviations: io_uring uses IORING_OP_NOP; landlock blocks /proc/version (not /etc/passwd); timerfd_settime skips on 32-bit allnoconfig; CONFIG_NET=n → ENOSYS handled alongside EAFNOSUPPORT in unix skip guard.
- **ns-ipc ENOSYS fix (PR #53, merged 2026-08-16):** `ns-ipc semop` exits non-zero when CONFIG_SYSVIPC=n (semget returns ENOSYS). Fix: add ENOSYS guard at the semget() call site. Caught by randdefconfig/riscv run on v7.1.8-rc1; verified 49/49 PASS on randdefconfig/riscv (v7.2-rc7).
- **programs quality hardening (PR #50, merged 2026-08-09):** arena-test + perf-event aligned to the serial-capture CFLAGS baseline: `CFLAGS_COMMON`/`CFLAGS_COMMON_GCC`/`CFLAGS_COMMON_CLANG`, musl-gcc for all arches, musl-clang quality gate for x86_64. arena-test debug output gated behind `VERBOSE=1` env var (getenv). perf-event upgraded from `-std=gnu11` to `-std=c11`. New top-level `tests/programs/Makefile` builds all three programs. New `tests/ci/test-arena-test.sh` and `tests/ci/test-perf-event.sh`. Bootstrap fixes for Debian/Ubuntu: `dpkg --add-architecture i386`, `linux-libc-dev:i386`, `libc6-dev-{arm64,riscv64}-cross`, musl-clang wrapper (`--target=x86_64-unknown-linux-musl -isystem/-B/-L`, no -nostdinc). `-Wno-unknown-warning-option` added for clang <16. Verified: make smoke PASS 43/43 all 8 combos on laptop + Hetzner.
- **serial-capture hardening (PR #49, merged 2026-08-09):** `sigaction()` replaces `signal()` (SA_RESTART cleared; VMIN=1/VTIME=0 replaces 100ms polling workaround); `strtol()` replaces `atoi()` with full error checking; baud table extended to 1.5Mbaud; `(tcflag_t)` casts fix sign-conversion; Makefile establishes `CFLAGS_COMMON`/`CFLAGS_COMMON_GCC`/`CFLAGS_COMMON_CLANG` dual-compiler musl baseline (GCC quality gate + Clang shipped); `musl-tools` added to bootstrap; `tests/ci/test-serial-capture.sh` (10 assertions). Verified: 5/5 × 43/43 PASS on VF2 with hardened binary.

## Directory Structure

```
kernel-test/
├── Makefile
├── lib/            core pipeline: fetch.sh fetch-next.sh fetch-stable-rc.sh checkout.sh build.sh initramfs.sh vm.sh report.sh diff.sh install.sh dmesg.sh + common.sh (shared arch helpers)
├── scripts/        on-demand tools: kconfig-check.sh kconfig-enumerate.sh build-kconfig.sh config-archive.sh config-bisect.sh canary-patch.sh migrate-reports.sh dev-test.sh hook-dev-test.sh verify-patch.sh
├── tests/
│   ├── 001_smoke.sh
│   ├── custom/     001_print-dmesg + 010_ … 480_ (49 scripts)
│   ├── ci/         host-side harness self-tests (test-*.sh, lib.sh, fixtures/)
│   ├── ns/         C binaries for namespace regression tests (ns-uts … ns-time, Makefile)
│   └── programs/   C helper programs injected into the initramfs (perf-event, arena-test, syscall-tests, snapshot)
├── configs/        *.config fragments applied post-config; <profile>-<arch>.config overlays; archive_passed/ + archive_failed/ (committed config archive)
├── docs/           per-branch design plans (plan-template.md + <slug>-plan.md)
├── memory/         this directory — persistent AI context
├── dmesg/          gitignored; raw dmesg captures + analysis files (make dmesg)
├── build/          gitignored; out-of-tree kernel builds + initramfs
├── cache/          gitignored; ccache
└── reports/        gitignored; HTML + txt reports per run
```

## Build Artifacts per (config, arch)

```
build/<config>-<arch>/
  build.status        STATUS=PASS|FAIL|TIMEOUT, START_TIME, DURATION, CONFIG_SHA256, KERNEL_TREE
  build.log           full make output
  .config             final resolved kernel config
  vm.status           BOOT=PASS|FAIL, TESTS_PASS, TESTS_FAIL, KUNIT_PASS, KUNIT_FAIL, FAILED_TESTS (space-sep list)
  dmesg.txt           serial console output
```

Report dir per run (`reports/<label>-<major.minor>-<date>-<version>/`, e.g. `mainline-7.2-2026-07-14_10-00-00-v7.2-rc2`):
```
  summary.txt / summary.html / summary.mail.txt
  vmstatus-<config>-<arch>.txt   copy of vm.status — used by lib/diff.sh for cross-run comparison
  diff-prev.txt                  auto-diff vs previous run (if vmstatus files exist)
  diff-baseline.txt              auto-diff vs pinned baseline (if reports/baseline symlink set)
  rand-sampled.config rand500config only: the 500 sampled =y lines
  randdef-disabled.config randdefconfig only: the 300 randomly disabled lines
```

## Test Protocol (serial output)

```
> TEST RUN: 010_check-proc
ok: /proc/version contains Linux
< TEST PASS: 010_check-proc
> TEST RUN: 100_network-loopback
< TEST FAIL: 100_network-loopback
BOOT_OK: kernel reached init
TEST_DONE
```

`vm.sh` counts `^< TEST PASS:` and `^< TEST FAIL:` lines.
`OVERALL=FAIL` when any build ≠ PASS, any boot ≠ PASS, TESTS_FAIL > 0, KUNIT_FAIL > 0, or config MISMATCH.
Exit codes: `0` = pass, `1` = test failure, `2` = infrastructure/build error.
KUnit: `vm.sh` detects `KTAP version` or `# Subtest:` in dmesg, strips ANSI codes, counts `ok`/`not ok` lines (suite summary lines included — one per suite, correctly reflect pass/fail state); report shows `kunit:N/N`.
