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
    │   exports: KERNEL_TREE (tilde-expanded, absolutified), ARCHS, CONFIGS,
    │            TIMEOUT, REPORT_DIR, V, TAG
    │
    ├── make fetch      → lib/fetch.sh
    │                         git fetch + auto-checkout latest -rc tag
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

`lib/fetch.sh` operates on the caller-provided `KERNEL_TREE` directory.

```
git -C "$KERNEL_TREE" fetch --tags origin
LATEST_RC=$(git -C "$KERNEL_TREE" tag -l 'v*-rc*' | sort -V | tail -1)
git -C "$KERNEL_TREE" checkout "$LATEST_RC"
```

The fetched tag name is exported as `KERNEL_VERSION` for use in report filenames.

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
poweroff -f
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
Linux <version> boot test report
Host: <uname -m>, <CPU model>, <RAM>
Started:  <ISO-8601>
Duration: <Xm YYs>
Result:   PASS

Config           Arch     Build    Boot         Tests    Started   Dur      Notes
------           ----     -----    ----         -----    -------   ---      -----
defconfig        x86_64   PASS     PASS         6/6      08:12:01  12s
defconfig        i386     PASS     PASS         0/0      08:12:13  8s
tinyconfig       x86_64   PASS     PASS         6/6      08:12:21  10s
tinyconfig       i386     PASS     PASS         0/0      08:12:31  9s
allnoconfig      x86_64   PASS     PASS         6/6      08:12:40  10s
allnoconfig      i386     PASS     PASS         0/0      08:12:50  8s
allmodconfig     x86_64   PASS     build-only   —        08:12:58  4m12s
allmodconfig     i386     PASS     build-only   —        08:17:10  4m05s

Full dmesg logs: reports/<run>/
```

**`summary.html`** — same data in an HTML table with pass=green / fail=red styling.

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
make info KERNEL_TREE=~/git/linux                        # show current version
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux       # pin a specific version
make KERNEL_TREE=~/git/linux                             # full pipeline
make KERNEL_TREE=~/git/linux ARCHS=x86_64               # single arch
make KERNEL_TREE=~/git/linux CONFIGS=defconfig           # single config
make build initramfs test report NO_FETCH=1 KERNEL_TREE=~/git/linux
make KERNEL_TREE=~/git/linux TIMEOUT=120                 # longer VM timeout
make KERNEL_TREE=~/git/linux V=1                         # verbose output
```

| Variable | Default | Description |
|---|---|---|
| `KERNEL_TREE` | `../linux` | Path to linux.git working tree; `~/...` and relative paths are accepted — expanded to absolute at parse time |
| `TAG` | _(none)_ | Tag or commit for `make checkout`; ignored by all other targets |
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
