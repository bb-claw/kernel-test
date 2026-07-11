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
| `lib/fetch.sh` | `git fetch` + checkout of latest `-rc` tag |
| `lib/build.sh` | Kernel build with ccache; out-of-tree `O=build/<config>-<arch>/` |
| `lib/initramfs.sh` | Assemble BusyBox cpio initramfs; inject test scripts |
| `lib/vm.sh` | Launch QEMU, capture serial console output, detect boot success/oops |
| `lib/report.sh` | Collate results; write `summary.html` and `summary.txt` |
| `tests/smoke.sh` | Minimal boot smoke: did we reach init without a panic or oops? |
| `tests/custom/*.sh` | User-provided test scripts (copy-in, run inside VM, check exit code) |

## Conventions

- All scripts use `#!/bin/bash` and `set -euo pipefail`
- Functions are lowercase_snake_case
- Constants are UPPER_SNAKE_CASE; the Makefile exports them into the environment before invoking lib scripts
- Makefile variables (`KERNEL_TREE`, `ARCHS`, `CONFIGS`, `TIMEOUT`, `REPORT_DIR`, `V`) are the public API
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

## Running locally

```sh
# Full pipeline
make KERNEL_TREE=/path/to/linux

# Partial run (build only, specific config and arch)
make build KERNEL_TREE=/path/to/linux CONFIGS=defconfig ARCHS=x86_64

# Verbose mode
make V=1 KERNEL_TREE=/path/to/linux
```

All output goes to stdout; the final report path is printed by the `report` target.
