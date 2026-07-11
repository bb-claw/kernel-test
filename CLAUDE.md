# CLAUDE.md — kernel-test

## Project purpose

This repo is a Bash-based harness for testing Linux release-candidate (-rc) kernels.
It builds kernels under multiple config profiles, boots them in QEMU/KVM with a minimal
BusyBox initramfs, runs tests inside the VM, and writes a local HTML/text report.
The goal is systematic community verification of each -rc kernel.

## Tech stack

- **Entry point:** `Makefile` — all commands are invoked via `make <target> [VAR=value]`
- **Language:** Bash for all lib scripts — no Python, no Ruby, no extra runtimes
- **Virtualization:** QEMU/KVM (`qemu-system-x86_64`, `qemu-system-i386`)
- **Userland:** BusyBox static binary packed into a cpio initramfs
- **Build cache:** ccache (always enabled; cache dir is `cache/`, gitignored)
- **Architectures:** `x86_64` and `i386`
- **Kernel configs:** `defconfig`, `tinyconfig`, `allnoconfig`, `allmodconfig`, `randconfig`, `rand500config`, `randdefconfig`; plus `localconfig` (not in default `CONFIGS`)
  - Bootable (build + VM test): `defconfig`, `tinyconfig`, `allnoconfig`, `rand500config`, `randdefconfig`, `localconfig`
  - Build-only (no VM boot): `allmodconfig` (image too large), `randconfig` (unpredictable boot)
  - `rand500config` — special: uses `tinyconfig` as base, samples 500 `=y` lines from a constrained `randconfig` generated in a temp dir (heavy subsystems excluded), applies the bootability fragment last; saves `rand-source.config` and `rand-sampled.config` into `build/<config>-<arch>/`
  - `randdefconfig` — uses `defconfig` as base, randomly disables 300 `=[ym]` options, applies a fragment that forces heavy subsystems off and re-pins bootability options; stays reliably under 5 minutes
  - `localconfig` — uses `/proc/config.gz` (running Manjaro kernel) as base + `configs/localconfig.config` fragment; for daily-driver builds; `make install` deploys to `/boot` via mkinitcpio + GRUB; x86_64 only
  - `randconfig` is constrained by `configs/randconfig.config` (disables modules + 5 heaviest subsystems) and subject to `BUILD_TIMEOUT` (default 600 s); exits with `STATUS=TIMEOUT` if exceeded
  - Config fragments in `configs/<profile>.config` are appended post-config and resolved via `olddefconfig`; used to re-enable the minimum options (TTY, serial, initramfs, BINFMT_ELF/SCRIPT) that stripped configs disable

## Key files

| File | Role |
|---|---|
| `Makefile` | Main entry point; defines all targets and variables; calls lib scripts |
| `lib/fetch.sh` | `git fetch` + auto-checkout; mainline rc mode (default) or stable release mode (`STABLE_RELEASE=X.Y`) |
| `lib/checkout.sh` | Fetch and checkout a specific tag or commit; verifies kernel Makefile version |
| `lib/build.sh` | Kernel build with ccache; out-of-tree `O=build/<config>-<arch>/` |
| `lib/initramfs.sh` | Assemble BusyBox cpio initramfs; inject test scripts |
| `lib/vm.sh` | Launch QEMU, capture serial console output, detect boot success/oops |
| `lib/report.sh` | Collate results; write `summary.html` and `summary.txt` |
| `lib/common.sh` | Shared helpers: `log`/`info`/`warn`/`die`, `require_env`, `is_build_only`, `read_kernel_makefile_version` |
| `tests/001_smoke.sh` | Minimal boot smoke: shell arithmetic, `/dev/null`, `/proc/version`, `/sys` |
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
| `.githooks/pre-commit` | Pre-commit hook: shellcheck on staged `.sh` files; executable bit on staged test scripts; guard against staged build artifacts |
| `.githooks/pre-push` | Pre-push hook: shellcheck on all tracked `.sh` files; executable bit on all test scripts |
| `lib/install.sh` | Install built kernel to `/boot` (Arch/Manjaro): modules, vmlinuz, mkinitcpio preset, grub-mkconfig |
| `tests/hardware/verify.sh` | Real-hardware verification for localconfig: NVMe, MT7921 WiFi, BT, AMD_PMC, K10TEMP, IDEAPAD_LAPTOP, AES-NI, BTRFS, exFAT; run on the booted laptop |
| `configs/rand500config.config` | Bootability fragment for rand500config (TTY, serial, initramfs) |
| `configs/randdefconfig.config` | Heavy subsystem force-off + bootability fragment for randdefconfig |
| `configs/randconfig.config` | Constraint fragment for randconfig (MODULE=n, heavy subsystems off) |
| `configs/localconfig.config` | Hardware fragment for Lenovo AMD Ryzen 7 5800H (NVMe, MT7921 WiFi, BT, AMD_PMC, AES-NI, BTRFS); applied on top of `/proc/config.gz` |

## Conventions

- Git hooks are in `.githooks/`; activate with `make hooks` (or automatically via `make bootstrap`); `pre-commit` checks staged files (shellcheck, executable bit, artifact guard); `pre-push` sweeps all tracked files
- All scripts use `#!/bin/bash` and `set -euo pipefail`
- Functions are lowercase_snake_case
- Constants are UPPER_SNAKE_CASE; the Makefile exports them into the environment before invoking lib scripts
- Makefile variables (`KERNEL_TREE`, `STABLE_KERNEL_TREE`, `STABLE_RELEASE`, `TAG`, `NO_FETCH`, `ARCHS`, `CONFIGS`, `TIMEOUT`, `BUILD_TIMEOUT`, `REPORT_DIR`, `V`) are the public API
- `BUILD_TIMEOUT` (default 600 s) wraps only the `bzImage` build step via `timeout`; exit 124 → `STATUS=TIMEOUT` in `build.status`
- `make all` always runs `report` even when build or test fails; the overall exit code still reflects failures — use `make all NO_FETCH=1 ...` rather than chaining `build initramfs test report` individually
- `KERNEL_TREE` is normalized at parse time: leading `~` is expanded and the path is made absolute via `$(abspath ...)`; pass `~/git/linux` or `../linux` freely
- When `STABLE_RELEASE` is set, `KERNEL_TREE` is overridden to `STABLE_KERNEL_TREE` (default: `~/git/linux-stable`) before normalization — all downstream scripts (build, test, report) automatically use the stable tree
- Lib scripts are invoked as subprocesses by the Makefile (not sourced), so they must not rely on shell state from each other
- VM serial output is captured live to `build/<config>-<arch>/dmesg.txt` and copied to `reports/<date>_<time>_<version>/dmesg-<config>-<arch>.txt` by the report step
- Test output protocol inside the VM: `/init` emits `> TEST RUN: <name>` before each script and `< TEST PASS: <name>` / `< TEST FAIL: <name>` after; `vm.sh` counts those markers for TESTS_PASS/TESTS_FAIL
- Report `OVERALL` is `FAIL` when any build status is non-PASS, any boot fails, or any test fails (`TESTS_FAIL > 0`)
- Exit codes: `0` = pass, `1` = test failure, `2` = infrastructure/build error
- Never write to the kernel source tree; all build artifacts go under `build/`

## How to add a test

1. Create `tests/custom/NNN_my-test.sh` where `NNN` is a 3-digit number (e.g. `150_my-test.sh`)
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

## What NOT to do

- Do not introduce Python, Go, or any non-shell dependency without explicit user approval
- Do not require root for the build steps; only QEMU may need it (use KVM group membership)
- Do not hardcode paths — use `KERNEL_TREE`, `BUILD_DIR`, `REPORT_DIR` variables
- Do not commit build artifacts, ccache, or reports — all are gitignored

## Fetching kernels

Two fetch modes are supported:

Both modes use `git ls-remote` to discover the latest matching tag (no objects
transferred), then fetch only that one tag with `--depth=1`. This is much faster
than `git fetch --tags` which downloads all tag objects.

**Mainline rc (default)** — discovers and fetches the latest `v*-rc*` tag from `KERNEL_TREE`:
```sh
make fetch KERNEL_TREE=~/git/linux-stable
```

**Stable release** — discovers and fetches the latest `vX.Y.*` tag (non-rc) from `STABLE_KERNEL_TREE`.
The remote URL is verified to contain `/stable/` or `linux-stable` before fetching:
```sh
make fetch STABLE_RELEASE=7.1
# → uses ~/git/linux-stable, checks out latest v7.1.x tag
```

Setting `STABLE_RELEASE` automatically redirects `KERNEL_TREE` to `STABLE_KERNEL_TREE`
for all pipeline stages — no extra flags needed for build, test, or report.

**Pin a specific version:**
```sh
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux        # mainline
make checkout TAG=v7.1.3 STABLE_RELEASE=7.1               # stable
```

**Skip fetch entirely:**
```sh
make all NO_FETCH=1 KERNEL_TREE=~/git/linux
```

## Running locally

```sh
# Show what is currently checked out
make info KERNEL_TREE=~/git/linux-stable

# Full pipeline — latest mainline rc (report always written even on failure)
make KERNEL_TREE=~/git/linux-stable

# Full pipeline — latest stable release (e.g. v7.1.x)
make STABLE_RELEASE=7.1

# Pin a specific version, then test without re-fetching
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux-stable
make all NO_FETCH=1 KERNEL_TREE=~/git/linux-stable

# Partial run — single config and arch
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64

# Test rand500config only (tinyconfig + 500 random options, bootable)
make all NO_FETCH=1 CONFIGS=rand500config ARCHS=x86_64

# Verbose mode
make V=1 KERNEL_TREE=~/git/linux-stable
```

Always use `make all NO_FETCH=1` (not `make build initramfs test report`) — `all` guarantees
the report is written even when build or test steps fail; individual target chaining stops at
the first failure.

All output goes to stdout; the final report path is printed by the `report` target.
