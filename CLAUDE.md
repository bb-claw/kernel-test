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
- **Kernel configs:** `defconfig`, `tinyconfig`, `allnoconfig`, `allmodconfig`
  - Bootable (build + VM test): `defconfig`, `tinyconfig`, `allnoconfig`
  - Build-only (no VM boot): `allmodconfig` (image too large for the minimal initramfs)
  - Config fragments in `configs/<profile>.config` are appended post-config and resolved via `olddefconfig`; used to re-enable the minimum options (TTY, serial, initramfs, BINFMT_ELF/SCRIPT, ACPI) that stripped configs disable

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
| `tests/smoke.sh` | Minimal boot smoke: did we reach init without a panic or oops? |
| `tests/custom/*.sh` | User-provided test scripts (copy-in, run inside VM, check exit code) |

## Conventions

- All scripts use `#!/bin/bash` and `set -euo pipefail`
- Functions are lowercase_snake_case
- Constants are UPPER_SNAKE_CASE; the Makefile exports them into the environment before invoking lib scripts
- Makefile variables (`KERNEL_TREE`, `STABLE_KERNEL_TREE`, `STABLE_RELEASE`, `TAG`, `NO_FETCH`, `ARCHS`, `CONFIGS`, `TIMEOUT`, `REPORT_DIR`, `V`) are the public API
- `KERNEL_TREE` is normalized at parse time: leading `~` is expanded and the path is made absolute via `$(abspath ...)`; pass `~/git/linux` or `../linux` freely
- When `STABLE_RELEASE` is set, `KERNEL_TREE` is overridden to `STABLE_KERNEL_TREE` (default: `~/git/linux-stable`) before normalization — all downstream scripts (build, test, report) automatically use the stable tree
- Lib scripts are invoked as subprocesses by the Makefile (not sourced), so they must not rely on shell state from each other
- VM serial output is captured live to `build/<config>-<arch>/dmesg.txt` and copied to `reports/<date>_<time>_<version>/dmesg-<config>-<arch>.txt` by the report step
- Exit codes: `0` = pass, `1` = test failure, `2` = infrastructure/build error
- Never write to the kernel source tree; all build artifacts go under `build/`

## How to add a test

1. Create `tests/custom/my-test.sh` (exit 0 = pass, non-zero = fail)
2. The harness automatically discovers and runs all `tests/custom/*.sh` inside the VM
3. Output lines starting with `PASS:` or `FAIL:` are parsed into the report table

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
make build initramfs test report NO_FETCH=1 KERNEL_TREE=~/git/linux
```

## Running locally

```sh
# Show what is currently checked out
make info KERNEL_TREE=~/git/linux-stable

# Full pipeline — latest mainline rc
make KERNEL_TREE=~/git/linux-stable

# Full pipeline — latest stable release (e.g. v7.1.x)
make STABLE_RELEASE=7.1

# Pin a specific version, then test without re-fetching
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux-stable
make build initramfs test report NO_FETCH=1 KERNEL_TREE=~/git/linux-stable

# Partial run (single config and arch)
make build initramfs test report NO_FETCH=1 \
    KERNEL_TREE=~/git/linux-stable CONFIGS=defconfig ARCHS=x86_64

# Verbose mode
make V=1 KERNEL_TREE=~/git/linux-stable
```

All output goes to stdout; the final report path is printed by the `report` target.
