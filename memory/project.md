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
  └─ lib/preflight.sh    hard-fail validation before build: host compiler, cross-compilers, QEMU binaries per ARCHS, disk space; auto-invoked by `make build`
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
| build.sh + report.sh prefer kernel Makefile for version | `git describe --tags --abbrev=0` walks to ancestor tag on stable-rc (e.g. `v7.1-rc7` instead of `v7.2.6-rc1`); `read_kernel_makefile_version` reads VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION directly and is always authoritative |
| `make extended` uses rc accumulator, not sequential sub-makes | A test failure in `full` (e.g. rand500config timeout) must not abort `ns-full` or `perf-build` — they are independent; `rc=0; $(MAKE) X \|\| rc=$$?` runs all three and exits non-zero if any failed; `perf-build` runs first so its status file exists when `full` and `ns-full` write their reports |
| `report.sh` sentinel for combined extended summary | `make extended` calls `report.sh` twice (once per phase); first pass writes `$BUILD_DIR/.report-extended-phase` (RUN_STAMP + CONFIGS); second pass reads it and prepends phase-1 configs so combined `summary.txt` covers all 10 configs; stale sentinel (different RUN_STAMP) is silently discarded; standalone `make full`/`make ns-full` unaffected |
| kunitrandconfig is build-only | Random KUnit module set; use kunitconfig for deterministic KUnit boot testing |
| preset auto-dispatch via $(notdir $(CURDIR)) | Same `make fetch` command works in mainline/stable/stable-rc clones; directory name selects presets/kernel-test-*.mk; `kernel-test-next` preset sets `LINUX_NEXT=1`, causing `make fetch` to error and redirect to `make fetch-next` |
| Per-(config,arch) initramfs | watchdog marker requires grepping per-build `.config` for `CONFIG_WATCHDOG=y`; one `initramfs-$CONFIG-$ARCH.cpio.gz` per pair → markers reflect actual config state; `build.status` prerequisite auto-rebuilds initramfs after kernel build |
| `KERNEL_VERSION` computed via grep, not `make kernelversion` | `make -s -C KERNEL_TREE kernelversion` triggers full Kbuild at Makefile parse time, adding 20+ s to every `make` invocation; direct grep of VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION from `KERNEL_TREE/Makefile` is instant — same logic as `lib/common.sh:read_kernel_makefile_version()` |
| `make info` uses `--exact-match` only for Tag (git) | `git describe HEAD` (no depth limit) walks the full DAG; on stable-rc clones with one stale mainline tag 1.4 M commits back this takes 10+ s; `Tag (Makefile)` and `Version file` already show the correct version |
| `CCACHE_MAX_SIZE=25G` default, tuning via `--set-config` | 5G default caused cache thrashing on localconfig builds (~4.6G output, 82% miss rate); settings written to `ccache.conf` via `--set-config` so they persist for standalone `ccache` invocations; `hard_link` excluded — `objtool` modifies `.o` files in-place for ORC unwinder, incompatible with read-only hard-linked cache entries |
| LLD auto-detected; `LINKER=lld\|bfd` written to `build.status` | Warm-cache builds spend nearly all time in vmlinux link; LLD is 6.8× faster on partial link (0.22s vs 1.50s), 1.6× on final link. `detect_lld()` in `common.sh` checks `ld.lld` ≥ kernel minimum (`scripts/min-tool-version.sh lld`, fallback 17.0.1). `USE_LLD=0` in `local.mk` disables. `LINKER=` appended to `build.status` via EXIT trap; shown in report headers. |
| `OBJCOPY=llvm-objcopy` alongside `LD=ld.lld` for cross-arch | LLD 18+ emits arm64/riscv ELF with section types that `aarch64-linux-gnu-objcopy` (binutils 2.40) does not recognise. When `llvm-objcopy` is in PATH: passed for all arches. When absent: LLD still used for x86_64/i386 (native ELF unaffected); arm64/riscv fall back to BFD; preflight warns. |
| Config cache: `.config-base` + `.config-cache-hash` per combo | `make tinyconfig ARCH=riscv` takes 29 s (kconfig scans full tree 3–4×); output is deterministic for a fixed kernel commit + fragment set. `build.sh` caches the pre-fragment `.config-base` keyed on `sha256(commit + fragments)`; on hit `kmake <base-config>` is skipped (~0 s). Sibling reuse (`_try_sibling_base`): random configs (rand500/randdef/kunitrand) borrow tinyconfig/defconfig base on cold runs; deterministic configs (kunitconfig/kunitnsconfig→defconfig; tinynsconfig→tinyconfig; defnsconfig→defconfig; vf2config→defconfig) do the same and write their own per-combo cache so warm runs skip the sibling. `make full`/`ns-full` order base configs first to maximise same-session hits. `NO_CONFIG_CACHE=1` forces regen. Not cached: `randconfig`, `localconfig`. |
| `PARALLEL_BUILDS=4` / `PARALLEL_VMS=4` defaults | All three orchestration loops (build, initramfs, test) run up to N jobs concurrently via `_enqueue`/`_flush` with `wait -n` sliding window. `wait -n` (bash 4.3+) frees a slot the moment *any* child finishes — not just the oldest — eliminating TCG starvation (riscv/arm64 finish in ~9 s; x86_64 TCG takes ~140 s). Per-build `-j` = `nproc / min(PARALLEL_BUILDS, BUILD_TOTAL)` (floor 2): small runs (e.g. 2-combo smoke) automatically get more slots per build. GNU make jobserver evaluated and rejected (PR #86): outer `-j$(PARALLEL_BUILDS)` creates only 4 tokens → inner makes get 1 cc1 slot each, slower than static `-j`. Tier-0 base configs flush before tier-1 to preserve sibling cache hits. Lower to 2 in `local.mk` on <8-core/<8G-RAM hosts. |
| `.build-active` / `.vm-active` sentinels + `.run-plan` | `build.sh` writes NPROC into `.build-active` on start (removed in EXIT trap); `vm.sh` touches `.vm-active` and removes it after `write_run_status`. `make monitor` polls these for live visibility. `.run-plan` written by `make build` (NOT `make test`) with `BUILD_TOTAL`, `TEST_TOTAL`, `CONFIGS`, `ARCHS`, `BOOT_CONFIGS`; monitor reads it to show `/ N total` and scope done-counts to the current run; mtime of `.run-plan` is the reference timestamp — only `build.status`/`vm.status` files newer than it count as "done" for this run. |
| `build.sh` writes `STATUS=INFRA_FAIL` before validation `die()` | Three early checks (bad arch, missing kernel tree, missing GCC) fired before `mkdir -p` and the sentinel write; a prior `STATUS=PASS` survived the early exit on repeat runs. Fix: `OUT_DIR` assignment, `mkdir -p`, and `STATUS=INFRA_FAIL` write now precede all validation. Covered by `tests/ci/test-build-errors.sh` (I1–I3). |
| Unified `INFO` log format across all pipeline output | `mklog.sh` uses `info()` so orchestration headers (`[fetch]`/`[build]`/`[programs]` etc.) carry the same `HH:MM:SS [elapsed] - - INFO  [tag] message` format as script-level messages; `preflight.sh` uses `info()`/`warn()`; `MAKEFLAGS += --no-print-directory` eliminates `make[N]: Entering/Leaving` noise; programs/ns per-binary lines routed through `bash lib/mklog.sh`; `$(Q)` suppresses compiler invocations at V=0. |
| `lib/metrics.sh` + `lib/monitor.sh` | `metrics.sh` aggregates per-run KPIs (build/test wall times, ccache hit rate delta, peak cc1/kbuild counts from `.monitor-samples`) into `metrics.txt` in the report dir and appends a Build Performance section to `summary.txt`/`summary.html`; called by `report.sh`. `monitor.sh` is a 2-second-refresh live dashboard (`make monitor` in a separate terminal) showing: BUILDS (active/done/total, cc1/kbuild/CPU/load/mem, CPU throttle warning when avg freq <80% of max), TESTS (active/done/total, VMs, wall time), CCACHE (this-run % + all-time %, size used/max, direct/preprocessed split, errors, cleanups — one `--show-stats` call per tick), delta vs last `metrics.txt`; ETA in header (`run: Xm Ys → ETA ~Xm Ys`) during active build/test phases; separator width adapts to terminal width via `tput cols` (min 60, max 100). |

## Current State

- **Tests:** 52 total (1 smoke + 51 custom; see test-inventory.md); next slot: 510_
- **Architectures:** x86_64 + i386 (KVM); arm64 + riscv (TCG). x86 falls back to TCG (2× timeout) without `/dev/kvm`. arm64 QEMU uses `-cpu cortex-a57` (ARMv8.0-A) — LSE atomics absent from `/proc/cpuinfo Features` is expected, not a regression. Toybox: x86_64→toybox-x86_64, i386→toybox-i686, arm64→toybox-aarch64, riscv→toybox-riscv64. Clang (`LLVM=1`) needs `clang`+`lld`+`llvm` (all three; clang alone doesn't pull in llvm on Arch or Debian). riscv needs `riscv64-linux-gnu-gcc` + `qemu-system-riscv64 ≥8.x` (bookworm-backports for B-extension).
- **Config profiles:** 9 default + 2 extra (localconfig x86_64-only; vf2config riscv-only JH7110). Two-layer fragments: arch-neutral base + arch overlay (serial driver, FPU; absent = silently skipped).
- **Fetch:** six clones (kernel-test / kernel-test-stable / kernel-test-stable-rc [rolling, 7.2.y] / kernel-test-stable-rc-7.1 [pinned] / kernel-test-stable-rc-7.2 [pinned] / kernel-test-next); preset auto-selected by directory name; kernel-test-next uses `make fetch-next`.
- **Hardware (VF2):** Arch serial group is `uucp`; relay may be CP210x (`10c4:ea60`) not CH340 (`1a86:7523`) — set in `local.mk`; atftpd requires `--user user.group` (no `nogroup` on Arch).

## Directory Structure

```
kernel-test/
├── Makefile
├── lib/            core pipeline: fetch.sh fetch-next.sh fetch-stable-rc.sh checkout.sh preflight.sh build.sh initramfs.sh vm.sh report.sh diff.sh install.sh dmesg.sh + common.sh (shared arch helpers) + mklog.sh (Makefile orchestration log lines)
├── scripts/        on-demand tools: kconfig-check.sh kconfig-enumerate.sh build-kconfig.sh config-archive.sh config-bisect.sh canary-patch.sh migrate-reports.sh dev-test.sh hook-dev-test.sh verify-patch.sh
├── tests/
│   ├── 001_smoke.sh
│   ├── custom/     001_print-dmesg + 010_ … 500_ (51 scripts)
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
  .config-base            pre-fragment config; cached before fragment application; keyed by sha256(commit+fragments)
  .config-base-commit     plain kernel commit hash (for cross-combo sibling reuse)
  .config-cache-hash      opaque sha256 key used to validate cache hits
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
