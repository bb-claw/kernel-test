# Design Document — kernel-test

**Version:** 0.1  
**Date:** 2026-07-09  
**Status:** Draft

---

## 1. Goal

Provide a reproducible, low-dependency harness that any Linux developer can run
on a standard x86 machine to verify a Linux -rc kernel and optionally contribute
a structured test report to the community.

---

## 2. Scope

**In scope:**
- Fetching the latest upstream -rc tag automatically
- Building the kernel for x86_64 and i386 under four config profiles
- Booting each build in QEMU/KVM with a minimal initramfs
- Running a boot smoke test and user-supplied custom scripts inside the VM
- Writing a pass/fail report as local HTML and plain text

**Out of scope (for now):**
- ARM64 / RISC-V builds
- Kernel selftests (`tools/testing/selftests`) — too heavyweight for the initial scope
- LTP — requires a larger rootfs
- Automated email submission to LKML
- CI/CD integration
- Multi-machine distributed testing

---

## 3. Architecture Overview

All user-facing commands go through `make`. The Makefile exports variables into the
environment and invokes lib scripts as subprocesses for each pipeline stage.

```
Makefile  (make all / make fetch / make checkout / make info / make build / ...)
    │
    │   exports: KERNEL_TREE (tilde-expanded, absolutified), STABLE_KERNEL_TREE,
    │            STABLE_RELEASE, TAG, NO_FETCH, ARCHS, CONFIGS, TIMEOUT, REPORT_DIR, V
    │
    ├── make fetch      → lib/fetch.sh
    │                         ls-remote to discover latest matching tag (no objects)
    │                         fetch only that one tag with --depth=1
    │                         mainline mode: latest v*-rc* from KERNEL_TREE
    │                         stable mode (STABLE_RELEASE=X.Y): latest vX.Y.* (non-rc)
    │                           from STABLE_KERNEL_TREE; remote URL verified
    │
    ├── make checkout   → lib/checkout.sh  (TAG=<tag-or-commit> required)
    │                         fetch ref if not local
    │                         git checkout TAG
    │                         verify: parse VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION
    │                                 from KERNEL_TREE/Makefile; warn on mismatch
    │                         touch KERNEL_TREE/Makefile (invalidates build artifacts)
    │                         write build/.kernel-version
    │
    ├── make info       (inline recipe)
    │                         show HEAD commit, git tag, kernel Makefile version,
    │                         and build/.kernel-version
    │
    ├── make build   → lib/build.sh        (for each config × arch)
    │                     make <config>        # generate .config
    │                     make -j$(nproc)      # build bzImage (ccache)
    │
    ├── make initramfs → lib/initramfs.sh  (for each arch)
    │                     copy BusyBox static binary
    │                     generate /init shell script
    │                     copy tests/smoke.sh + tests/custom/*.sh
    │                     pack with cpio + gzip → initramfs-<arch>.cpio.gz
    │
    ├── make test    → lib/vm.sh           (for each config × arch)
    │                     qemu-system-<arch> -kernel bzImage -initrd initramfs.cpio.gz
    │                     capture serial → dmesg-<config>-<arch>.txt
    │                     detect: "BOOT_OK:" line = booted
    │                     detect: "Kernel panic" / "BUG:" / "Oops:" = failure
    │                     timeout: $TIMEOUT seconds (default 60)
    │
    └── make report  → lib/report.sh
                          aggregate all results
                          write reports/<date>_<time>_<version>/summary.html
                          write reports/<date>_<time>_<version>/summary.txt
```

---

## 4. Pipeline Detail

### 4.1 Fetch

`lib/fetch.sh` supports two modes, selected by the `STABLE_RELEASE` variable:

Both modes use the same two-step strategy to avoid downloading unnecessary objects:

**Step 1 — discover the latest matching tag via `ls-remote` (no objects transferred):**
```
git ls-remote --tags origin "refs/tags/v*-rc*"   # mainline
git ls-remote --tags origin "refs/tags/v7.1.*"   # stable, STABLE_RELEASE=7.1
```
The output is filtered (exclude `^{}` peel entries, exclude `-rc` in stable mode),
sorted with `sort -V`, and the highest version is selected.

**Step 2 — fetch only that one tag if not already local:**
```
git fetch --depth=1 origin refs/tags/v7.2-rc2:refs/tags/v7.2-rc2
```
If the tag commit is already in the local object store, this step is skipped entirely.

**Mainline rc mode (default — `STABLE_RELEASE` unset):**
- Tag pattern: `refs/tags/v*-rc*`
- Tree: `KERNEL_TREE` (default `../linux`)

**Stable release mode (`STABLE_RELEASE=7.1`):**
- The Makefile overrides `KERNEL_TREE` → `STABLE_KERNEL_TREE` (default `~/git/linux-stable`)
- `fetch.sh` verifies `git remote get-url origin` contains `/stable/` or `linux-stable` — dies if not
- Tag pattern: `refs/tags/v7.1.*`, excluding `-rc` tags

The checked-out tag name is written to `build/.kernel-version` and read by
`KERNEL_VERSION` in the Makefile for use in report filenames and `[build]`/`[test]`
header lines.

### 4.2 Build

Each (config, arch) pair gets an isolated out-of-tree build directory:

```
build/
  defconfig-x86_64/
  defconfig-i386/
  tinyconfig-x86_64/
  tinyconfig-i386/
  allnoconfig-x86_64/
  allnoconfig-i386/
  allmodconfig-x86_64/
  allmodconfig-i386/
```

Build command (x86_64 example):
```sh
# Step 1: generate .config
make -C "$KERNEL_TREE" O="$BUILD_DIR" ARCH=x86_64 "$CONFIG"
# Step 1b: apply fragment if configs/<config>.config exists
cat "configs/$CONFIG.config" >> "$BUILD_DIR/.config"
make -C "$KERNEL_TREE" O="$BUILD_DIR" ARCH=x86_64 olddefconfig
# Step 2: build
make -C "$KERNEL_TREE" O="$BUILD_DIR" ARCH=x86_64 -j"$(nproc)" bzImage
```

`KBUILD_BUILD_TIMESTAMP` is set to a fixed value to make builds reproducible.
`CC` and `HOSTCC` are set to `ccache gcc`; `CCACHE_DIR` points to `cache/`.

**Config fragments:** `configs/<profile>.config` is appended to `.config` after the
kernel config target runs, then `make olddefconfig` resolves Kconfig dependencies.
This is used instead of `KCONFIG_ALLCONFIG` because some targets (e.g. `tinyconfig`)
override that variable on the command line.

**allmodconfig note:** `allmodconfig` is build-only — the resulting kernel is not
booted (it is too large for the minimal initramfs). It exists purely to catch
compilation errors. All other profiles (`defconfig`, `tinyconfig`, `allnoconfig`)
are booted and tested.

### 4.3 Initramfs

The initramfs is built once per architecture (shared across config variants):

```
initramfs-<arch>/
  bin/          # busybox + symlinks (sh, ls, cat, dmesg, ...)
  dev/          # null, console, tty (mknod)
  proc/
  sys/
  tmp/
  tests/        # smoke.sh + custom/*.sh
  init          # generated shell script (see below)
```

`/init` script:
```sh
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

echo "BOOT_OK: kernel reached init"

for t in /tests/*.sh; do
    sh "$t" && echo "PASS: $t" || echo "FAIL: $t"
done

echo "TEST_DONE"
reboot -f
```

The initramfs is packed:
```sh
find initramfs-<arch>/ | cpio -oH newc | gzip > initramfs-<arch>.cpio.gz
```

### 4.4 VM Execution

QEMU is launched with a timeout (default 60 s) and serial output redirected to a file:

```sh
timeout 60 qemu-system-x86_64 \
    -enable-kvm \
    -M q35 \
    -m 512M \
    -display none \
    -no-reboot \
    -kernel "$BZIMAGE" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0 panic=5 quiet" \
    -serial file:"$DMESG_FILE"
```

Note: `-display none` is used instead of `-nographic`. With `-nographic`, QEMU implicitly
binds serial0 to stdio, causing `-serial file:` to register as serial1 — kernel output
would go to /dev/null instead of the capture file.

i386 uses `qemu-system-i386` with `ARCH=i386` kernel and the same flags.

**Success detection** (parsed from `$DMESG_FILE`):
- `BOOT_OK:` line present → booted successfully
- `TEST_DONE` line present → tests completed

**Failure detection:**
- `Kernel panic` in output
- `BUG:` or `Oops:` in output
- QEMU exit code non-zero (including timeout)

### 4.5 Report

`lib/report.sh` reads result files written by the VM step and produces:

**`summary.txt`** (plain text, suitable for mailing list):
```
Linux v7.2-rc2 boot test report
Repository: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
Commit:     abc1234def567890abcdef1234567890abcdef12
Host:       x86_64  |  Intel Core i9-13900K  |  65536 MiB
Started:    2026-07-11T10:30:00Z
Duration:   8m42s
Result:     PASS

Config           Arch     Build    Boot         Tests    Started   Dur      Notes
------           ----     -----    ----         -----    -------   ---      -----
defconfig        x86_64   PASS     PASS         6/6      10:30:01  12s
defconfig        i386     PASS     PASS         0/0      10:30:13  8s
tinyconfig       x86_64   PASS     PASS         6/6      10:30:21  10s
tinyconfig       i386     PASS     PASS         0/0      10:30:31  9s
allnoconfig      x86_64   PASS     PASS         6/6      10:30:40  10s
allnoconfig      i386     PASS     PASS         0/0      10:30:50  8s
allmodconfig     x86_64   PASS     build-only   —        10:30:58  4m12s
allmodconfig     i386     PASS     build-only   —        10:35:10  4m05s

Full dmesg logs: reports/<run>/
```

`Repository` and `Commit` are read from `git remote get-url origin` and
`git rev-parse HEAD` on `KERNEL_TREE` at report generation time — unambiguous
whether the run was against mainline or a stable tree.

**`summary.html`** — same data in an HTML table with pass=green / fail=red styling,
plus Repository and Commit fields in the header.

---

## 5. Result Storage

```
reports/
  2026-07-09_08-12-01_v6.15-rc2/
    summary.html
    summary.txt
    dmesg-defconfig-x86_64.txt
    dmesg-defconfig-i386.txt
    dmesg-tinyconfig-x86_64.txt
    dmesg-tinyconfig-i386.txt
    dmesg-allnoconfig-x86_64.txt
    dmesg-allnoconfig-i386.txt
    build-allmodconfig-x86_64.log
    build-allmodconfig-i386.log
```

Reports directory is gitignored. Users choose what to share publicly.

---

## 6. Make Interface

### Targets

| Target | Description |
|---|---|
| `make` / `make all` | Full pipeline: fetch → build → initramfs → test → report |
| `make fetch` | Fetch and auto-checkout the latest -rc tag |
| `make checkout TAG=v7.2-rc2` | Fetch and checkout a specific tag or commit; verifies Makefile version |
| `make info` | Show HEAD commit, git tag, kernel Makefile version, and version file |
| `make build` | Build kernels for all `CONFIGS` × `ARCHS` |
| `make initramfs` | Assemble the BusyBox cpio initramfs for each arch |
| `make test` | Boot each (config, arch) in QEMU and run tests |
| `make report` | Aggregate results into HTML and plain-text report |
| `make clean` | Remove `build/` and `cache/` |
| `make distclean` | Remove `build/`, `cache/`, and `reports/` |
| `make help` | Print available targets and variables |

### Variables

All variables have defaults and can be overridden on the command line:

```
# Mainline rc
make KERNEL_TREE=~/git/linux-stable                      # full pipeline, latest rc
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux-stable
make build initramfs test report NO_FETCH=1 KERNEL_TREE=~/git/linux-stable
make info KERNEL_TREE=~/git/linux-stable                 # show current version

# Stable release
make STABLE_RELEASE=7.1                                  # full pipeline, latest v7.1.x
make checkout TAG=v7.1.3 STABLE_RELEASE=7.1              # pin exact stable tag
make build initramfs test report NO_FETCH=1 STABLE_RELEASE=7.1

# Scoped runs
make KERNEL_TREE=~/git/linux-stable ARCHS=x86_64         # single arch
make KERNEL_TREE=~/git/linux-stable CONFIGS=defconfig    # single config
make V=1 KERNEL_TREE=~/git/linux-stable                  # verbose output
```

| Variable | Default | Description |
|---|---|---|
| `KERNEL_TREE` | `../linux` | Path to mainline linux.git; `~/...` and relative paths accepted — expanded to absolute at parse time. Overridden automatically when `STABLE_RELEASE` is set. |
| `STABLE_KERNEL_TREE` | `~/git/linux-stable` | Path to stable linux.git clone; used automatically when `STABLE_RELEASE` is set |
| `STABLE_RELEASE` | _(none)_ | Stable series to fetch, e.g. `7.1`; triggers stable mode in `fetch.sh` and overrides `KERNEL_TREE` to `STABLE_KERNEL_TREE` |
| `TAG` | _(none)_ | Tag or commit for `make checkout`; ignored by all other targets |
| `NO_FETCH` | `0` | Set to `1` to skip `make fetch` and use the current checkout |
| `ARCHS` | `x86_64 i386` | Space-separated architectures to test |
| `CONFIGS` | `tinyconfig allnoconfig defconfig allmodconfig` | Space-separated config profiles |
| `TIMEOUT` | `60` | VM boot timeout in seconds |
| `REPORT_DIR` | `reports` | Directory for output reports |
| `V` | `0` | Set to `1` for verbose build and VM output |

---

## 7. Dependencies

| Package | Min version | Notes |
|---|---|---|
| bash | 4.0 | `set -euo pipefail`, arrays |
| gcc | 12.0 | C23 features used by recent kernels |
| gcc-multilib | — | i386 cross-compile on x86_64 host |
| ccache | 3.7 | Compiler cache |
| qemu-system-x86 | 6.0 | `-enable-kvm`, `-serial file:` |
| busybox | 1.35 (static) | Initramfs userland |
| cpio | — | Initramfs packing |
| git | 2.30 | `git -C`, `--sort=version:refname` |

---

## 8. Security Considerations

- The harness runs kernel builds as the current user (no sudo needed)
- QEMU runs as the current user with KVM access (add user to `kvm` group)
- No network access inside the VM (QEMU launched without `-net` flags)
- Kernel source tree is never modified; all output is in `build/` and `reports/`

---

## 9. Future Work

The following are deferred and out of scope for v0.1:

| Feature | Rationale for deferral |
|---|---|
| ARM64 / RISC-V | Requires cross-toolchain setup |
| Kernel selftests | Needs larger initramfs + more packages |
| LTP | Same; also requires a full rootfs |
| Automated LKML email | Out-of-scope; user reviews before sending |
| CI integration | Per-user infra varies too much |
| `allmodconfig` boot test | Image too large for minimal initramfs |
| Multiple -rc versions side-by-side | Not needed for community reporting use case |

---

## 10. Glossary

| Term | Meaning |
|---|---|
| `-rc` | Release candidate — a pre-release Linux kernel tag (e.g. `v6.15-rc2`) |
| `bzImage` | Compressed bootable x86 kernel image produced by `make bzImage` |
| `initramfs` | Initial RAM filesystem loaded by the bootloader before the real rootfs |
| `cpio` | Archive format used to pack the initramfs |
| `KVM` | Kernel-based Virtual Machine — Linux hypervisor for near-native VM speed |
| `ccache` | Compiler cache that speeds up repeated builds by caching object files |
| `LKML` | Linux Kernel Mailing List — the primary communication channel for kernel development |
