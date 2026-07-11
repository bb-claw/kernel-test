# kernel-test

A Bash-based harness for building and testing Linux release-candidate (-rc) kernels
inside QEMU/KVM virtual machines, aimed at contributing boot and regression reports
back to the Linux kernel community.

## What it does

1. Fetches the latest `-rc` tag from Linus's upstream tree
2. Builds the kernel under four configuration profiles: `defconfig`, `tinyconfig`, `allnoconfig`, `allmodconfig`
3. Constructs a minimal BusyBox initramfs (cpio)
4. Boots each bootable kernel variant in QEMU/KVM for both `x86_64` and `i386`
5. Runs a boot smoke test and custom userland scripts inside the VM
6. Writes a pass/fail report as a local HTML/text file

## Prerequisites

| Tool | Purpose |
|---|---|
| `gcc` + `gcc-multilib` | Build kernels for x86_64 and i386 |
| `make` | Kernel build system |
| `ccache` | Compiler cache for incremental builds |
| `qemu-system-x86` | VM execution (KVM acceleration required) |
| `busybox` (static) | Minimal userland inside the initramfs |
| `cpio`, `gzip` | Initramfs packing |
| `git` | Fetching the upstream kernel tree |
| `bc`, `flex`, `bison`, `libelf` | Kernel build dependencies |

On Arch/Manjaro:
```sh
sudo pacman -S gcc gcc-multilib make ccache qemu-system-x86 busybox cpio git bc flex bison libelf
```

On Debian/Ubuntu:
```sh
sudo apt install gcc gcc-multilib make ccache qemu-system-x86 busybox-static cpio git bc flex bison libelf-dev
```

## Quick Start

```sh
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git kernel-src
git clone https://github.com/YOUR_USERNAME/kernel-test.git
cd kernel-test

# Full pipeline: fetch latest -rc, build, boot, test, report
make KERNEL_TREE=../kernel-src

# Test a single architecture
make KERNEL_TREE=../kernel-src ARCHS=x86_64

# Test a single config variant
make KERNEL_TREE=../kernel-src CONFIGS=defconfig

# Skip fetch, use current HEAD
make build initramfs test report KERNEL_TREE=../kernel-src

# Show all available targets
make help
```

Reports are written to `reports/YYYY-MM-DD_HH-MM-SS_<kernel-version>/`.

## Directory Layout

```
kernel-test/
├── Makefile              # Main entry point — all commands go through make
├── lib/
│   ├── fetch.sh          # Fetch latest -rc tag from upstream
│   ├── build.sh          # Kernel build logic (ccache, out-of-tree O=)
│   ├── initramfs.sh      # Build BusyBox cpio initramfs
│   ├── vm.sh             # QEMU/KVM launch and serial console capture
│   └── report.sh         # Aggregate results into HTML/text report
├── tests/
│   ├── smoke.sh          # Boot smoke test (reaches init, no oops)
│   └── custom/           # Drop your own *.sh test scripts here
├── configs/              # Saved .config files (optional overrides)
├── reports/              # Output directory for test reports
└── cache/                # ccache directory (gitignored)
```

## Make Targets

| Target | Description |
|---|---|
| `make` / `make all` | Full pipeline: fetch → build → initramfs → test → report |
| `make fetch` | Fetch and checkout the latest -rc tag automatically |
| `make checkout TAG=v7.2-rc2` | Fetch and checkout a specific tag or commit |
| `make info` | Show current tag/commit and kernel Makefile version |
| `make build` | Build kernels for all configs × archs |
| `make initramfs` | Assemble the BusyBox cpio initramfs |
| `make test` | Boot VMs and run tests |
| `make report` | Generate the HTML/text report from last test results |
| `make clean` | Remove `build/` and `cache/` |
| `make distclean` | Remove `build/`, `cache/`, and `reports/` |
| `make help` | List all targets with descriptions |

## Make Variables

Override on the command line:

| Variable | Default | Description |
|---|---|---|
| `KERNEL_TREE` | `../linux` | Path to a cloned linux.git working tree (`~/...` and relative paths are accepted) |
| `TAG` | _(none)_ | Tag or commit to check out; required by `make checkout` |
| `ARCHS` | `x86_64 i386` | Space-separated list of target architectures |
| `CONFIGS` | `tinyconfig allnoconfig defconfig allmodconfig` | Space-separated list of config profiles |
| `TIMEOUT` | `60` | VM boot timeout in seconds |
| `REPORT_DIR` | `reports` | Output directory for test reports |
| `V` | `0` | Set to `1` for verbose output |

## Configuration Profiles

| Profile | Boot tested | Description |
|---|---|---|
| `defconfig` | yes | Architecture default — broad baseline coverage |
| `tinyconfig` | yes | Minimal kernel — tests lower bound of functionality |
| `allnoconfig` | yes | Everything disabled — tests absolute minimum boot path |
| `allmodconfig` | no (build only) | All options as modules — catches build-time regressions |

`tinyconfig` and `allnoconfig` use a `configs/<profile>.config` fragment applied after
the kernel config target runs to re-enable the minimum options needed for a bootable VM
(TTY, serial console, initramfs, ELF/script execution, ACPI power-off).

## Adding Custom Tests

Drop a `.sh` script into `tests/custom/`. It will be copied into the initramfs and
executed inside the VM. The script should exit `0` on success and non-zero on failure.
Output is captured and included in the report.

Example: `tests/custom/check-proc.sh`
```sh
#!/bin/sh
grep -q "Linux" /proc/version && echo "PASS: /proc/version OK" || { echo "FAIL: /proc/version missing"; exit 1; }
```

## Report Format

After each run, `reports/<date>_<time>_<kernel>/` contains:

- `summary.html` — pass/fail table per config × architecture × test
- `summary.txt` — plain-text version for mailing list submission
- `dmesg-<config>-<arch>.txt` — kernel log per variant

## Community Contribution

Test reports can be sent to the Linux kernel mailing list (LKML) or relevant subsystem
lists. Use `summary.txt` as the body. The standard subject format is:

```
[REPORT] Linux <version> boot test: <PASS|FAIL> on x86_64/i386
```

See [Reporting Bugs](https://www.kernel.org/doc/html/latest/admin-guide/reporting-issues.html)
for LKML submission guidelines.

## License

GPL-2.0 — same license as the Linux kernel.
