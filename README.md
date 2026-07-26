# kernel-test

A Bash-based harness for building and testing Linux release-candidate (-rc) kernels
inside QEMU/KVM virtual machines, aimed at contributing boot and regression reports
back to the Linux kernel community.

## What it does

1. Fetches the latest `-rc` tag from Linus's upstream tree (or a stable point release)
2. Builds the kernel under nine configuration profiles: `defconfig`, `tinyconfig`, `allnoconfig`, `kunitconfig`, `kunitrandconfig`, `allmodconfig`, `randconfig`, `rand500config`, `randdefconfig`
3. Constructs a minimal Toybox initramfs (cpio) for each architecture
4. Boots each bootable kernel variant in QEMU/KVM for `x86_64`, `i386`, `arm64`, and `riscv` (arm64/riscv run in TCG on an x86 host)
5. Runs numbered test scripts inside the VM in order; each test emits structured pass/fail output; KUnit KTAP results also parsed
6. Writes a pass/fail report as a local HTML/text file — always written even on build or test failure

## Prerequisites

`make bootstrap` installs all dependencies automatically (distro-aware: pacman/apt/dnf/zypper):

```sh
make bootstrap   # needs sudo once; also activates git hooks
```

| Tool | Purpose |
|---|---|
| `gcc` + `gcc-multilib` | Build kernels for x86_64 and i386 |
| `aarch64-linux-gnu-gcc` | Cross-compile for arm64 |
| `riscv64-linux-gnu-gcc` | Cross-compile for riscv |
| `ccache` | Compiler cache for incremental builds |
| `qemu-system-x86` | VM execution for x86_64 / i386 (KVM acceleration) |
| `qemu-system-aarch64` | VM execution for arm64 (TCG on x86 host) |
| `qemu-system-riscv64` | VM execution for riscv (TCG on x86 host) |
| `cpio`, `gzip`, `lzop` | Initramfs packing + kernel LZO compression |
| `bc`, `flex`, `bison`, `libelf`, `pahole` | Kernel build dependencies |
| Toybox static binary | Minimal userland inside the initramfs (downloaded by `make bootstrap`) |

## Quick Start

```sh
# Clone the stable kernel tree (contains both mainline rc and stable release tags)
git clone --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git ~/git/linux-stable

git clone https://github.com/bb-claw/kernel-test.git
cd kernel-test
make bootstrap                          # install build deps (needs sudo, once) + activate git hooks

make KERNEL_TREE=~/git/linux-stable     # full pipeline: fetch latest rc, build, test, report
make help                               # list all targets and variables
```

Reports are written to `reports/YYYY-MM-DD_HH-MM-SS_<kernel-version>/`.

## Practical Examples

### Test a new mainline rc (most common workflow)

When Linus announces a new rc on LKML (e.g. Linux 7.2-rc3):

```sh
# Option A — auto-fetch the latest rc and run everything
make KERNEL_TREE=~/git/linux-stable

# Option B — pin the exact announced version, then run
make checkout TAG=v7.2-rc3 KERNEL_TREE=~/git/linux-stable
make all NO_FETCH=1 KERNEL_TREE=~/git/linux-stable

# Check what is currently checked out before running
make info KERNEL_TREE=~/git/linux-stable
```

> **Note:** Always use `make all NO_FETCH=1` rather than chaining `build initramfs test report`
> individually — `all` guarantees the report is written even when a build or test step fails.
> When a build fails or times out, `make test` automatically skips that config and tests
> the ones that did build successfully.

### Test a specific stable release

When Greg announces a stable release (e.g. 7.1.3):

```sh
# Auto-fetch latest 7.1.x release and run everything
make STABLE_RELEASE=7.1

# Pin the exact version
make checkout TAG=v7.1.3 STABLE_RELEASE=7.1
make all NO_FETCH=1 STABLE_RELEASE=7.1

# With older GCC (some stable releases fail on GCC 16 — use gcc-15)
make fetch STABLE_RELEASE=7.1
make all   NO_FETCH=1 STABLE_RELEASE=7.1 GCC=gcc-15
```

`STABLE_RELEASE` automatically uses `~/git/linux-stable` and verifies the remote
is a stable tree before fetching.

> **Note:** run `make clean` when switching between kernel trees (mainline ↔ stable).
> Build directories contain generated headers tied to the source tree they were built
> from; reusing them across trees causes subtle mismatches.

### Build and install a daily-driver kernel from a stable tree

```sh
# Build localconfig against stable 7.1.x (BUILD_TIMEOUT=0 — larger than defconfig)
make build   NO_FETCH=1 STABLE_RELEASE=7.1 CONFIGS=localconfig ARCHS=x86_64 BUILD_TIMEOUT=0 GCC=gcc-15

# Install — KERNEL_TREE is read automatically from build.status; no need to repeat STABLE_RELEASE
make install CONFIGS=localconfig ARCHS=x86_64
```

### Quick single-arch build to verify a config

```sh
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64
```

### Verbose output for debugging

```sh
make all NO_FETCH=1 KERNEL_TREE=~/git/linux-stable V=1
```

## Directory Layout

```
kernel-test/
├── Makefile              # Main entry point — all commands go through make
├── lib/                  # Core pipeline scripts (fetch → build → initramfs → vm → report)
│   ├── common.sh         # Shared helpers + arch helpers (arch_cross_compile, arch_kernel_image, ...)
│   ├── fetch.sh          # Fetch latest -rc tag from upstream
│   ├── build.sh          # Kernel build (ccache, out-of-tree O=)
│   ├── initramfs.sh      # Build Toybox cpio initramfs + inject tests
│   ├── vm.sh             # QEMU/KVM launch and serial console capture
│   ├── report.sh         # Aggregate results into HTML/text report
│   ├── diff.sh           # Compare two report dirs for regressions/fixes
│   ├── install.sh        # Install kernel to /boot (Arch/Manjaro)
│   ├── dmesg.sh          # Capture and analyse host kernel dmesg
│   └── bootstrap.sh      # Install build/test dependencies + Toybox binaries
├── scripts/              # On-demand tools (kconfig sweep, bisect, archive, canary)
│   ├── build-kconfig.sh  # Exhaustive per-option build+boot sweep (make kconfig-build)
│   ├── config-bisect.sh  # Binary-search a failing archived config (make bisect)
│   ├── config-archive.sh # Archive passing/failing configs by SHA256 (make config-archive)
│   ├── kconfig-check.sh  # Static analysis for missing Kconfig selects (make kconfig-check)
│   └── canary-patch.sh   # Patch kernel tree with boot canary module (make canary-patch)
├── tests/
│   ├── 001_smoke.sh      # Boot smoke test (reaches init, no oops/panic)
│   ├── custom/           # Functional kernel-path tests (run in NNN_ order; next: 290_)
│   │   ├── 010_check-proc.sh  … 280_proc-self-extended.sh
│   └── hardware/
│       └── verify.sh     # Real-hardware check for localconfig (run on the booted laptop)
├── .githooks/
│   ├── pre-commit        # shellcheck + executable bit; artifact guard; inventory sync
│   ├── commit-msg        # Enforce conventional commit format
│   └── pre-push          # Full repo sweep; design doc check; memory size check; awk ban
├── configs/              # Config fragments + arch overlays; archive_passed/ + archive_failed/
├── docs/                 # Per-feature design docs (<slug>-plan.md) + workflow guides
├── memory/               # Persistent AI context (auto-memory for Claude Code)
├── reports/              # gitignored; HTML + text reports per run
└── cache/                # gitignored; ccache
```

## Make Targets

| Target | Description |
|---|---|
| `make` / `make all` | Full pipeline: fetch → build → initramfs → test → report |
| `make fetch` | Fetch and checkout the latest -rc tag automatically |
| `make checkout TAG=v7.2-rc2` | Fetch and checkout a specific tag or commit |
| `make info` | Show current tag/commit and kernel Makefile version |
| `make smoke` | Quick sanity: kunitconfig + tinyconfig, all archs |
| `make full` | Broader: 5 bootable configs, all archs |
| `make build` | Build kernels for all configs × archs |
| `make initramfs` | Assemble the Toybox cpio initramfs |
| `make test` | Boot VMs and run tests |
| `make report` | Generate the HTML/text report from last test results |
| `make diff` | Compare latest two same-label report runs for regressions |
| `make baseline` | Pin current run as baseline for future diffs |
| `make config-archive` | Scan reports and populate `configs/archive_passed/` + `configs/archive_failed/` |
| `make replay CONFIG_FILE=` | Replay a specific archived `.config` through the pipeline |
| `make bisect CONFIG_FILE=` | Binary-search a failing archived config for the responsible option |
| `make kconfig-build SUBSYSTEM=` | Exhaustive per-option build+boot sweep for a subsystem Kconfig |
| `make kconfig-check SUBSYSTEM=` | Static analysis for missing Kconfig `select` dependencies |
| `make canary-patch` | Patch kernel tree with boot canary built-in module |
| `make install` | Install built kernel to `/boot`; update mkinitcpio + GRUB (Arch/Manjaro, needs sudo) |
| `make bootstrap` | Install build/test dependencies (distro-aware, needs sudo) + activate git hooks |
| `make hooks` | Activate git hooks only (no package install) |
| `make clean` | Remove `build/` and `cache/` |
| `make distclean` | Remove `build/`, `cache/`, and `reports/` |
| `make help` | List all targets with descriptions |

## Fetching Kernels

The harness supports two fetch modes controlled by `STABLE_RELEASE`.

### Mainline rc (default)

Fetches the latest `-rc` tag from `KERNEL_TREE`:

```sh
make fetch KERNEL_TREE=~/git/linux
```

### Stable releases

Fetches the latest point release for a given stable series from `STABLE_KERNEL_TREE`
(default: `~/git/linux-stable`). The remote is verified to be a stable tree before
fetching — the origin URL must contain `/stable/` or `linux-stable`:

```sh
make fetch STABLE_RELEASE=7.1
# → checks out latest v7.1.x tag from ~/git/linux-stable
```

Setting `STABLE_RELEASE` automatically redirects `KERNEL_TREE` to `STABLE_KERNEL_TREE`,
so all subsequent build, test, and report steps use the stable tree without further flags.

Override the stable tree path if needed:

```sh
make fetch STABLE_RELEASE=7.1 STABLE_KERNEL_TREE=/path/to/linux-stable
```

### Pinning a specific version

Skip auto-fetch and check out an exact tag or commit:

```sh
make checkout TAG=v7.2-rc2                          # mainline
make checkout TAG=v7.1.3 STABLE_RELEASE=7.1         # stable (uses STABLE_KERNEL_TREE)
```

### Skip fetch entirely

Use `NO_FETCH=1` to build and test whatever is currently checked out:

```sh
make all NO_FETCH=1 KERNEL_TREE=~/git/linux
```

## Make Variables

Override on the command line:

| Variable | Default | Description |
|---|---|---|
| `KERNEL_TREE` | `../linux` | Path to mainline linux.git working tree (`~/...` and relative paths accepted) |
| `STABLE_KERNEL_TREE` | `~/git/linux-stable` | Path to stable linux.git clone; used automatically when `STABLE_RELEASE` is set |
| `STABLE_RELEASE` | _(none)_ | Stable series to fetch, e.g. `7.1`; selects latest `v7.1.*` tag and switches to `STABLE_KERNEL_TREE` |
| `TAG` | _(none)_ | Exact tag or commit for `make checkout` |
| `NO_FETCH` | `0` | Set to `1` to skip `make fetch` and use the current checkout |
| `NO_BUILD` | `0` | Set to `1` to skip kernel build and reuse existing `build/<config>-<arch>/` artifacts |
| `ARCHS` | `x86_64 i386 arm64 riscv` | Space-separated list of target architectures |
| `CONFIGS` | all 9 profiles | Space-separated list of config profiles (`localconfig` not in default list — requires `/proc/config.gz`) |
| `TIMEOUT` | `60` | VM boot timeout in seconds (arm64/riscv automatically doubled) |
| `BUILD_TIMEOUT` | `1200` | Per-kernel build timeout in seconds; exit 124 recorded as `STATUS=TIMEOUT`; set to `0` for localconfig |
| `GCC` | `gcc` | Compiler binary; e.g. `GCC=gcc-15` for stable kernels that predate GCC 16 |
| `REPORT_DIR` | `reports` | Output directory for test reports |
| `V` | `0` | Set to `1` for verbose output |

## Configuration Profiles

| Profile | Boot tested | Description |
|---|---|---|
| `defconfig` | yes | Architecture default — broad baseline coverage |
| `tinyconfig` | yes | Minimal kernel — tests lower bound of functionality |
| `allnoconfig` | yes | Everything disabled — tests absolute minimum boot path |
| `kunitconfig` | yes | `defconfig` base + KUnit framework + core test suites; KTAP output parsed and reported as `kunit:N/N` |
| `kunitrandconfig` | yes | `defconfig` base + all available KUnit modules; random set per run (rebuild required); KTAP tracked |
| `rand500config` | yes | `tinyconfig` base + 500 random `=y` options from a constrained randconfig; fast, varied, reproducibly bootable |
| `randdefconfig` | yes | `defconfig` base with 300 randomly disabled options; heavy subsystems forced off to stay under 5 min |
| `localconfig` | yes | `/proc/config.gz` base (running distro kernel) + hardware fragment; daily-driver builds; install with `make install`; not in the default CONFIGS list |
| `allmodconfig` | no (build only) | All options as modules — catches build-time regressions |
| `randconfig` | no (build only) | Fully random config — catches compile-time regressions; constrained to stay under `BUILD_TIMEOUT` |

`tinyconfig`, `allnoconfig`, `rand500config`, and `randdefconfig` use a `configs/<profile>.config`
fragment applied after the kernel config target runs to re-enable the minimum options needed for a
bootable VM (TTY, serial console, initramfs, ELF/script execution).

`rand500config` is handled specially by `build.sh`: it generates a constrained `randconfig` in a
temp directory (applying `configs/randconfig.config` to exclude heavy subsystems), samples 500 `=y`
lines from it, appends those to the `tinyconfig` base, then applies the bootability fragment last so
those options always win. The sampled lines are saved to `build/rand500config-<arch>/rand-sampled.config`
for inspection.

`randdefconfig` starts from `defconfig`, randomly disables 300 `=[ym]` options, then applies
`configs/randdefconfig.config` which forces heavy subsystems off (DRM, SOUND, STAGING, INFINIBAND,
MEDIA_SUPPORT) and re-pins bootability options. This keeps build time reliably under 5 minutes
on a 16-core machine.

## Adding Custom Tests

Create a numbered `.sh` script in `tests/custom/` — the `NNN_` prefix controls run order.
Tests run in ascending filename order inside the VM. Leave gaps in the numbering (010, 020, …)
so new tests can be inserted without renaming others.

The script should exit `0` on success and non-zero on failure. Use `ok:` / `FAIL:` / `skip:`
prefixes for per-assertion output. The `/init` runner wraps each script with structured
markers that `vm.sh` counts:

```
> TEST RUN: 190_my-test
ok: something worked
FAIL: something broke
< TEST FAIL: 190_my-test
```

Example: `tests/custom/190_my-test.sh`
```sh
#!/bin/sh
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -r /proc/version ] && ok "/proc/version readable" || fail "/proc/version missing"
[ $fails -eq 0 ] || exit 1
```

## Report Format

After each run, `reports/<date>_<time>_<kernel>/` contains:

- `summary.html` — pass/fail table per config × architecture × test; Overall pass/fail badge; linked file index; failed test names highlighted in red in the Notes column
- `summary.txt` — plain-text version with LKML preamble + full results table; failed test names listed in Notes column
- `summary.mail.txt` — preamble only (Subject line + metadata); paste as email intro without the table
- `dmesg-<config>-<arch>.txt` — full kernel serial output per variant
- `kconfig-<config>-<arch>.config` — exact `.config` used for that build
- `rand-sampled-<config>-<arch>.config` — the 500 sampled lines (rand500config only)
- `randdef-disabled-<config>-<arch>.config` — the 300 randomly disabled options (randdefconfig only)
- `build-<config>-<arch>.log` — build log (all configs; useful for spotting warnings on passing builds)

The report is always written — even when build or test steps fail — so there is always
an artifact to inspect after a run. `report.sh` exits with code 1 when `OVERALL=FAIL`
(any build failure, boot failure, test failure, or config fingerprint mismatch), so
`make` and CI correctly surface the failure.

## Community Contribution

Test reports can be sent to the Linux kernel mailing list (LKML) or relevant subsystem
lists. Use `summary.txt` as the body — it contains the full preamble + results table.
For a standalone email intro without the table, use `summary.mail.txt`.

The preamble format:

```
Subject: [REPORT] Linux <version> boot test: <PASS|FAIL> on x86_64/i386
build and booted: PASS
Repository:       <kernel remote URL>
Commit:           <HEAD SHA>
Host:             x86_64  |  AMD Ryzen 7 5800H  |  15729 MiB
Tested ARCH:      x86_64  i386

Tested-by: Your Name <your@email>

---

<full results table>
```

See [Reporting Bugs](https://www.kernel.org/doc/html/latest/admin-guide/reporting-issues.html)
for LKML submission guidelines.

## License

GPL-2.0 — same license as the Linux kernel.
