# Project — kernel-test

## Purpose

Reproducible harness for verifying Linux release-candidate (-rc) and stable kernels.
Builds under multiple config profiles, boots in QEMU/KVM, runs functional tests inside
the VM, and produces a local HTML + plain-text report suitable for LKML submission.
Goal: systematic community verification of each -rc kernel.

## Architecture

```
make all
  └─ lib/fetch.sh        discover + fetch latest tag (ls-remote, --depth=1)
  └─ lib/build.sh        cross-compile kernel per (config × arch), ccache; clears vm.status on start
  └─ lib/initramfs.sh    Toybox cpio initramfs + inject test scripts
  └─ lib/vm.sh           QEMU boot (KVM for x86, TCG for arm64), capture serial, count TEST PASS/FAIL + KUnit KTAP ok/not ok
  └─ lib/report.sh       aggregate status files → summary.html + summary.txt; copies vm.status; auto-diffs vs prev run + baseline
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
| Sanitizers excluded from randconfig constraints | KCOV/KASAN crash on tinyconfig base; excluding prevents false boot failures |
| build.sh deletes vm.status at start | Failed builds never show stale test results from a prior run |

## Current State (2026-07-12)

- **Architectures:** x86_64 + i386 (default, KVM); arm64 opt-in (`ARCHS="x86_64 i386 arm64"`, TCG, requires `aarch64-linux-gnu-gcc`); Toybox mapping: x86_64→toybox-x86_64, i386→toybox-i686, arm64→toybox-aarch64
- **Config profiles:** 9 (defconfig tinyconfig allnoconfig kunitconfig kunitrandconfig allmodconfig randconfig rand500config randdefconfig)
- **Tests:** 26 total (1 smoke + 25 custom; see test-inventory.md); next slot: 250_
- **Kernel tree:** `~/git/linux-stable` (contains both mainline rc and stable point release tags)
- **Current kernel:** v7.2-rc2

## Directory Structure

```
kernel-test/
├── Makefile
├── lib/            fetch.sh build.sh initramfs.sh vm.sh report.sh diff.sh common.sh checkout.sh install.sh dmesg.sh
├── tests/
│   ├── 001_smoke.sh
│   └── custom/     001_print-dmesg + 010_ … 240_ (25 scripts)
├── configs/        *.config fragments applied post-config
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
