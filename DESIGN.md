# Design Document — kernel-test

**Version:** 0.1  
**Date:** 2026-07-11  
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
- Building the kernel for x86_64 and i386 under eight config profiles
- Booting each build in QEMU/KVM with a minimal initramfs
- Running a boot smoke test and functional kernel-path tests inside the VM (network, RNG, tmpfs stress, fork/exec, sysctl)
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
    │                     make <config>        # generate .config (rand500config: tinyconfig + 500 sampled =y lines)
    │                     apply configs/<config>.config fragment if present
    │                     timeout $BUILD_TIMEOUT make -j$(nproc) bzImage (ccache)
    │                     write build/<config>-<arch>/build.status (PASS|FAIL|TIMEOUT)
    │
    ├── make initramfs → lib/initramfs.sh  (for each arch)
    │                     copy BusyBox static binary
    │                     generate /init shell script with > TEST RUN / < TEST PASS/FAIL markers
    │                     copy tests/001_smoke.sh + tests/custom/NNN_*.sh (in filename order)
    │                     pack with cpio + gzip → initramfs-<arch>.cpio.gz
    │
    ├── make test    → lib/vm.sh           (for each config × arch)
    │                     skip config if build.status != STATUS=PASS (prints SKIP (build TIMEOUT/FAIL))
    │                     qemu-system-<arch> -kernel bzImage -initrd initramfs.cpio.gz
    │                     capture serial → dmesg-<config>-<arch>.txt
    │                     detect: "BOOT_OK:" line = booted
    │                     detect: "Kernel panic" / "Oops:" = failure
    │                     count: "^< TEST PASS:" / "^< TEST FAIL:" lines
    │                     count: KUnit KTAP ok/not ok lines (indented 4+ spaces after timestamp)
    │                     timeout: $TIMEOUT seconds (default 60)
    │
    └── make report  → lib/report.sh       (always runs — even after build/test failure)
                          aggregate build.status + vm.status for all (config, arch)
                          OVERALL=FAIL if any build!=PASS, boot!=PASS, TESTS_FAIL>0, or KUNIT_FAIL>0
                          copy kconfig-*, dmesg-*, rand-sampled-*, randdef-disabled-* into report dir
                          write reports/<date>_<time>_<version>/summary.html + summary.txt
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
  defconfig-x86_64/         # build.status, .config, dmesg.txt, vm.status
  defconfig-i386/
  tinyconfig-x86_64/
  tinyconfig-i386/
  allnoconfig-x86_64/
  allnoconfig-i386/
  kunitconfig-x86_64/       # boot+test; vm.status includes KUNIT_PASS/KUNIT_FAIL
  kunitconfig-i386/
  rand500config-x86_64/     # also: rand-source.config, rand-sampled.config
  rand500config-i386/
  randdefconfig-x86_64/     # also: randdef-disabled.config
  randdefconfig-i386/
  allmodconfig-x86_64/      # build-only: build.log instead of dmesg.txt/vm.status
  allmodconfig-i386/
  randconfig-x86_64/
  randconfig-i386/
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

**Build-only configs (`BUILD_ONLY_CONFIGS`):** `allmodconfig` and `randconfig` are not booted.
`allmodconfig` is too large for the minimal initramfs; `randconfig` may produce a kernel with
unpredictable boot behavior — its value is in catching compile-time regressions.
`randconfig` is constrained by `configs/randconfig.config` (`CONFIG_MODULES=n` + 5 heavy
subsystems disabled) and subject to `BUILD_TIMEOUT`.

**rand500config:** handled specially in `build.sh`:
1. `make tinyconfig` — tiny, known-bootable base
2. Generate a fresh `randconfig` in a temp dir; apply `configs/randconfig.config` constraints (no modules, heavy subsystems off); run `olddefconfig` to resolve; sample 500 `CONFIG_*=y` lines with `shuf -n 500`
3. Append those to `.config`, then apply `configs/rand500config.config` (bootability fragment) last
4. `make olddefconfig` — resolve all dependencies

Saves `rand-source.config` (full constrained randconfig) and `rand-sampled.config` (the 500 sampled
lines) in `build/rand500config-<arch>/` for inspection. The bootability fragment is applied last so
TTY, serial console, initramfs, and ELF options always win over any conflicting random selection.
The 500-line count compensates for dependency attrition: many options get disabled by `olddefconfig`
when their prerequisites are absent in the tinyconfig base.

**randdefconfig:** handled specially in `build.sh`:
1. `make defconfig` — broad, coherent baseline
2. Randomly disable 300 `=[ym]` options (`shuf -n 300 | sed 's/=[ym]$/=n/'`); append to `.config`
3. Apply `configs/randdefconfig.config`: force heavy subsystems off (DRM, SOUND, STAGING, INFINIBAND, MEDIA_SUPPORT) and re-pin bootability options; run `olddefconfig`

Saves `randdef-disabled.config` (the 300 disabled lines) in `build/randdefconfig-<arch>/`.
Heavy subsystem force-off keeps build time reliably under 5 minutes on a 16-core machine.

**kunitconfig:** handled specially in `build.sh` (not a kernel make target):
1. `make defconfig` — broad, coherent baseline with networking and common drivers
2. Apply `configs/kunitconfig.config`: enable `CONFIG_KUNIT=y` + core test suites (lib/ data structures, mm/ SLUB)
3. `make olddefconfig` — resolve dependencies

KUnit tests run automatically during boot via `do_initcalls` (before `/init`), emit KTAP output to
the serial console, and are parsed by `vm.sh`: indented `ok`/`not ok` lines (4+ spaces after the
timestamp) are individual test results; non-indented suite summaries are excluded to avoid
double-counting. Results stored as `KUNIT_PASS`/`KUNIT_FAIL` in `vm.status`. Shell tests from the
initramfs also run as normal. Report shows `kunit:N/N` (and `sh:N/N` if shell tests also ran).
x86_64 defconfig+KUnit build takes ~10–12 min; set `BUILD_TIMEOUT=1200` (the default) or higher.

**localconfig:** handled specially in `build.sh` (not a kernel make target):
1. Decompress `/proc/config.gz` (running Manjaro kernel config) into `$OUT_DIR/.config`
2. `make olddefconfig` — adapts the config to the new kernel version
3. Apply `configs/localconfig.config` via the standard step 1b fragment path; run `olddefconfig`

Requires `CONFIG_IKCONFIG_PROC=y` in the running kernel (standard on Manjaro). The Manjaro base
provides a full distro config; the fragment pins hardware-specific options (NVMe, MT7921E WiFi,
Bluetooth/btmtk, AMD_PMC, K10TEMP, IDEAPAD_LAPTOP, AES-NI, BTRFS, exFAT) and sets
`CONFIG_LOCALVERSION="-localconfig"`. Not in the default `CONFIGS` list. Build with
`BUILD_TIMEOUT=0` (larger than defconfig; can exceed the 1200s default). Install with `make install`.

**BUILD_TIMEOUT:** applies only to the `bzImage` build step via GNU `timeout(1)`. Default is 1200 s
(20 min), which covers defconfig and kunitconfig on x86_64 (~10–12 min). If exceeded, `build.sh`
exits 124 and writes `STATUS=TIMEOUT` to `build.status` (distinct from `STATUS=FAIL`). The `make test`
loop skips any config with a non-PASS build status and reports `SKIP (build TIMEOUT)` or `SKIP (build FAIL)`.

### 4.3 Initramfs

The initramfs is built once per architecture (shared across config variants):

```
initramfs-<arch>/
  bin/          # busybox + symlinks (sh, ls, cat, dmesg, ...)
  dev/          # null, console (mknod fallback if devtmpfs unavailable)
  proc/
  sys/
  tmp/
  tests/        # 001_smoke.sh + custom/NNN_*.sh (all in filename order)
  init          # generated shell script (see below)
```

`/init` script (runs tests in filename-sorted order, emits structured markers):
```sh
#!/bin/sh
mount -t proc     none /proc 2>/dev/null || true
mount -t sysfs    none /sys  2>/dev/null || true
mount -t devtmpfs none /dev  2>/dev/null || { mknod /dev/console ...; mknod /dev/null ...; }

echo "BOOT_OK: kernel reached init"

for t in /tests/*.sh; do
    [ -f "$t" ] || continue
    name=$(basename "$t" .sh)
    echo "> TEST RUN: $name"
    if sh "$t"; then
        echo "< TEST PASS: $name"
    else
        echo "< TEST FAIL: $name"
    fi
done

echo "TEST_DONE"
reboot -f
```

`vm.sh` counts `^< TEST PASS:` and `^< TEST FAIL:` lines to derive `TESTS_PASS` and `TESTS_FAIL`.

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

**Boot detection** (parsed from `$DMESG_FILE`):
- `BOOT_OK:` line present → kernel reached `/init`
- `Kernel panic` or `Oops:` → `BOOT_STATUS=FAIL`
- QEMU exit 124 → timeout before reaching init
- `TEST_DONE` line present → all test scripts completed

**Test counting:**
- `^< TEST PASS: <name>` → increment `PASS_COUNT` (one per passing test script)
- `^< TEST FAIL: <name>` → increment `FAIL_COUNT` (one per failing test script)
- `TESTS_TOTAL = PASS_COUNT + FAIL_COUNT`

### 4.5 Report

`lib/report.sh` reads `build.status` and `vm.status` files written by earlier stages and
always runs — even when build or test steps failed — so there is always an artifact to inspect.

**OVERALL result logic:**
- `OVERALL=FAIL` if any `build.status` has `STATUS != PASS`
- `OVERALL=FAIL` if any `vm.status` has `BOOT != PASS` (and config is not build-only)
- `OVERALL=FAIL` if any `vm.status` has `TESTS_FAIL > 0`
- `OVERALL=FAIL` if any `vm.status` has `KUNIT_FAIL > 0`

**`summary.txt`** (plain text, suitable for mailing list):
```
Linux v7.2-rc2 boot test report
Repository: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
Commit:     8cdeaa50eae8dad34885515f62559ee83e7e8dda
Host:       x86_64  |  AMD Ryzen 7 5800H  |  31939 MiB
Started:    2026-07-11T12:44:28Z
Duration:   1m16s
Result:     PASS

Config           Arch     Build    Boot         Tests           Started   Dur      Notes
------           ----     -----    ----         -----           -------   ---      -----
defconfig        x86_64   PASS     PASS         15/15           10:30:01  12s
tinyconfig       x86_64   PASS     PASS         10/15           10:30:21  10s
allnoconfig      x86_64   PASS     PASS         10/15           10:30:40  10s
kunitconfig      x86_64   PASS     PASS         kunit:42/42     10:30:58  11m23s
rand500config    x86_64   PASS     PASS         13/15           10:42:21  53s
randdefconfig    x86_64   PASS     PASS         14/15           10:43:14  4m01s
allmodconfig     x86_64   PASS     build-only   —               10:47:15  4m12s
randconfig       x86_64   PASS     build-only   —               10:51:27  3m20s

Report dir: reports/<run>/
```

`Repository` and `Commit` are read from `git remote get-url origin` and `git rev-parse HEAD`
at report generation time — unambiguous whether the run was against mainline or a stable tree.

**`summary.html`** — same data as an HTML table with pass=green / fail=red / timeout=red styling.

---

## 5. Result Storage

```
reports/
  2026-07-11_12-44-28_v7.2-rc2/
    summary.html
    summary.txt
    dmesg-defconfig-x86_64.txt          # serial console output per bootable variant
    dmesg-tinyconfig-x86_64.txt
    dmesg-allnoconfig-x86_64.txt
    dmesg-rand500config-x86_64.txt
    dmesg-randdefconfig-x86_64.txt
    kconfig-defconfig-x86_64.config     # exact .config used for each build
    kconfig-tinyconfig-x86_64.config
    kconfig-allnoconfig-x86_64.config
    kconfig-rand500config-x86_64.config
    kconfig-randdefconfig-x86_64.config
    kconfig-allmodconfig-x86_64.config
    kconfig-randconfig-x86_64.config
    rand-sampled-rand500config-x86_64.config      # the 500 randomly sampled lines
    randdef-disabled-randdefconfig-x86_64.config  # the 300 randomly disabled lines
    build-defconfig-x86_64.log          # build log for every config (warnings on PASS builds matter)
    build-tinyconfig-x86_64.log
    build-kunitconfig-x86_64.log
    build-allmodconfig-x86_64.log
    build-randconfig-x86_64.log
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
| `make install` | Install built kernel to `/boot`; modules, custom mkinitcpio conf + preset, grub-mkconfig (Arch/Manjaro, needs sudo) |
| `make bootstrap` | Install build/test dependencies (distro-aware, needs sudo) + activate git hooks |
| `make hooks` | Activate git hooks only (`git config core.hooksPath .githooks`) |
| `make clean` | Remove `build/` and `cache/` |
| `make distclean` | Remove `build/`, `cache/`, and `reports/` |
| `make help` | Print available targets and variables |

### Variables

All variables have defaults and can be overridden on the command line:

```
# Mainline rc
make KERNEL_TREE=~/git/linux-stable                      # full pipeline, latest rc
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux-stable
make all NO_FETCH=1 KERNEL_TREE=~/git/linux-stable       # always writes report
make info KERNEL_TREE=~/git/linux-stable                 # show current version

# Stable release
make STABLE_RELEASE=7.1                                  # full pipeline, latest v7.1.x
make checkout TAG=v7.1.3 STABLE_RELEASE=7.1              # pin exact stable tag
make all NO_FETCH=1 STABLE_RELEASE=7.1

# Scoped runs
make all NO_FETCH=1 ARCHS=x86_64                         # single arch
make all NO_FETCH=1 CONFIGS=defconfig                    # single config
make all NO_FETCH=1 CONFIGS=rand500config ARCHS=x86_64   # rand500config only
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
| `CONFIGS` | `tinyconfig allnoconfig defconfig kunitconfig allmodconfig randconfig rand500config randdefconfig` | Space-separated config profiles |
| `TIMEOUT` | `60` | VM boot timeout in seconds |
| `BUILD_TIMEOUT` | `1200` | bzImage build timeout in seconds; exit 124 → `STATUS=TIMEOUT`; set to `0` for localconfig |
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
