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
  └─ lib/build.sh        cross-compile kernel per (config × arch), ccache
  └─ lib/initramfs.sh    BusyBox cpio initramfs + inject test scripts
  └─ lib/vm.sh           QEMU/KVM boot, capture serial, count TEST PASS/FAIL
  └─ lib/report.sh       aggregate status files → summary.html + summary.txt
```

All user-facing commands go through `make`. Makefile exports env vars; lib scripts
are subprocesses (not sourced), so they carry no shell state between stages.

## Key Decisions

| Decision | Rationale |
|---|---|
| Bash only | No extra runtimes; any Linux box can run it |
| BusyBox static binary | No package manager, no rootfs; just a cpio + the binary |
| Out-of-tree builds `O=build/<config>-<arch>/` | Isolates artifacts; enables parallel builds |
| ccache always on | 2–10× rebuild speedup; `cache/` is gitignored |
| `make all` always runs `report` | Even on build/test failure there is always an artifact |
| Config fragment via `cat >> .config + olddefconfig` | Reliable for all targets; `KCONFIG_ALLCONFIG` is overridden by `tinyconfig` internally |
| `BUILD_TIMEOUT` wraps only bzImage step | Prevents runaway builds; exit 124 = TIMEOUT |
| Sanitizers excluded from randconfig constraints | KCOV/KASAN crash on tinyconfig base (no infrastructure); excluding prevents false boot failures |

## Current State (2026-07-11)

- **Architectures:** x86_64 (full tests), i386 (boot-only; BusyBox is 64-bit → C fallback init)
- **Config profiles:** 7 (see config-profiles.md)
- **Tests:** 16 total (1 smoke + 15 custom; see test-inventory.md)
- **Kernel tree:** `~/git/linux-stable` (contains both mainline rc and stable point release tags)
- **Current kernel:** v7.2-rc2

## Directory Structure

```
kernel-test/
├── Makefile
├── lib/            fetch.sh build.sh initramfs.sh vm.sh report.sh common.sh checkout.sh
├── tests/
│   ├── 001_smoke.sh
│   └── custom/     010_ … 140_ (15 scripts)
├── configs/        *.config fragments applied post-config
├── memory/         this directory
├── build/          gitignored; out-of-tree kernel builds + initramfs
├── cache/          gitignored; ccache
└── reports/        gitignored; HTML + txt reports per run
```

## Build Artifacts per (config, arch)

```
build/<config>-<arch>/
  build.status        STATUS=PASS|FAIL|TIMEOUT, START_TIME, DURATION, CONFIG_SHA256
  build.log           full make output
  .config             final resolved kernel config
  vm.status           BOOT=PASS|FAIL, TESTS_PASS, TESTS_FAIL, TESTS_TOTAL, FAIL_REASON
  dmesg.txt           serial console output
  rand-sampled.config rand500config only: the 500 sampled =y lines
  randdef-disabled.config randdefconfig only: the 300 randomly disabled lines
```

## Report Artifacts

```
reports/YYYY-MM-DD_HH-MM-SS_<version>/
  summary.html / summary.txt
  dmesg-<config>-<arch>.txt
  kconfig-<config>-<arch>.config      SHA256-verified against build.status
  rand-sampled-<config>-<arch>.config
  randdef-disabled-<config>-<arch>.config
  build-<config>-<arch>.log           build-only configs only
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
`OVERALL=FAIL` when any build ≠ PASS, any boot ≠ PASS, or TESTS_FAIL > 0.
