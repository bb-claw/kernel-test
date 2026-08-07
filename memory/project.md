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
  └─ lib/initramfs.sh    Toybox cpio initramfs; inject tests/custom/*.sh + ns-* binaries (tests/ns/) + perf-event + arena-test (tests/programs/)
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

## Current State (2026-07-26)

- **Architectures:** x86_64 + i386 + arm64 + riscv (all default); x86 uses KVM when `/dev/kvm` is accessible, falls back to TCG (2× timeout) on non-KVM hosts (e.g. Hetzner); arm64/riscv always use TCG (riscv requires `riscv64-linux-gnu-gcc`, `qemu-system-riscv64 ≥8.x` — bookworm-backports for QEMU B-extension support); Toybox mapping: x86_64→toybox-x86_64, i386→toybox-i686, arm64→toybox-aarch64, riscv→toybox-riscv64; Clang builds (`LLVM=1`) require `clang` + `lld` + `llvm` — all three packages installed by `make bootstrap` (clang does not pull in llvm on Arch or Debian)
- **Config profiles:** 9 (defconfig tinyconfig allnoconfig kunitconfig kunitrandconfig allmodconfig randconfig rand500config randdefconfig); each uses two-layer fragments: arch-neutral base (`configs/<profile>.config`) + arch overlay (`configs/<profile>-<arch>.config` — serial driver, FPU; absent = silently skipped)
- **Tests:** 42 total (1 smoke + 41 custom; see test-inventory.md); next slot: 420_
- **Fetch strategy:** four clones (`kernel-test`, `kernel-test-stable`, `kernel-test-stable-rc`, `kernel-test-next`), each auto-loads preset by directory name; `make fetch` dispatches correctly in the first three; `kernel-test-next` uses `make fetch-next` (linux-next has no rc tags); `~/git/linux-next` is the kernel tree for `kernel-test-next`
- **Current kernel (mainline clone):** v7.2-rc6
- **Hetzner-staging (stable-rc clone):** first full run 2026-07-26, v7.1.5-rc2, PASS 30/30 all 8 combos (tinyconfig+defconfig × 4 archs); TCG timings: i386 ~6 min (slowest), x86_64 ~2.5 min, arm64/riscv ~3–8 s (backports QEMU ≥8.x)

## Directory Structure

```
kernel-test/
├── Makefile
├── lib/            core pipeline: fetch.sh fetch-next.sh fetch-stable-rc.sh checkout.sh build.sh initramfs.sh vm.sh report.sh diff.sh install.sh dmesg.sh + common.sh (shared arch helpers)
├── scripts/        on-demand tools: kconfig-check.sh kconfig-enumerate.sh build-kconfig.sh config-archive.sh config-bisect.sh canary-patch.sh migrate-reports.sh
├── tests/
│   ├── 001_smoke.sh
│   ├── custom/     001_print-dmesg + 010_ … 410_ (41 scripts)
│   ├── ci/         host-side harness self-tests (test-*.sh, lib.sh, fixtures/)
│   ├── ns/         C binaries for namespace regression tests (ns-uts … ns-time, Makefile)
│   └── programs/   C helper programs injected into the initramfs (perf-event, arena-test)
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
