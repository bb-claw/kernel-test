# arm64 Architecture Support — Plan

Branch: `feat/arm64-support`
Start date: 2026-07-12

---

## Situation

The harness currently supports x86_64 and i386. Both run via KVM on the local
x86 host. Adding arm64 doubles ISA coverage with minimal new test code — the
test scripts are architecture-agnostic; only the build/VM/initramfs layers need
updating.

---

## Key Differences from x86

| Aspect | x86_64 / i386 | arm64 |
|---|---|---|
| Cross-compiler | none (native / gcc -m32) | `aarch64-linux-gnu-gcc` |
| Kernel image | `arch/x86/boot/bzImage` | `arch/arm64/boot/Image` |
| Build target | `bzImage` | `Image` |
| QEMU binary | `qemu-system-x86_64` / `qemu-system-i386` | `qemu-system-aarch64` |
| QEMU machine | `q35` / `pc` | `virt` |
| QEMU CPU flag | (none needed) | `-cpu cortex-a57` |
| KVM on x86 host | yes (same ISA) | no (TCG only) |
| Serial console | `ttyS0` (8250 UART) | `ttyAMA0` (PL011 UART) |
| Toybox binary | `toybox-x86_64` / `toybox-i686` | `toybox-aarch64` |

---

## Scope

Files changed:

- `lib/build.sh` — arch case: CROSS_COMPILE, KERNEL_IMAGE_NAME, `localconfig` guard (x86_64 only)
- `lib/vm.sh` — arm64 case: machine/cpu/image path/console; rename BZIMAGE→KERNEL_IMAGE; KVM guard
- `lib/initramfs.sh` — add `arm64) TOYBOX_ARCH=aarch64`
- `lib/bootstrap.sh` — cross-compiler packages, qemu-system-aarch64, toybox-aarch64 download
- `configs/*.config` — add `CONFIG_SERIAL_AMBA_PL011=y CONFIG_SERIAL_AMBA_PL011_CONSOLE=y` to bootability fragments; `olddefconfig` silently drops unavailable options so these are safe on x86

No changes to: test scripts, report.sh, common.sh, checkout.sh.

---

## Design Decisions

### Cross-compiler derived inside build.sh

`CROSS_COMPILE` is not a user-visible Makefile variable; it is set inside
`build.sh` based on `$ARCH`. For arm64, `CROSS_COMPILE=aarch64-linux-gnu-` and
`KERNEL_CC=aarch64-linux-gnu-gcc`. The existing `GCC=` variable overrides the
*host* compiler only (x86_64/i386 native builds). arm64 always uses the
standard cross-compiler prefix.

### KVM skipped for arm64

KVM only accelerates VMs whose ISA matches the host. On an x86_64 host, arm64
must run in TCG (software emulation). `vm.sh` skips the `-enable-kvm` flag when
`ARCH == arm64`. TCG is notably slower but acceptable for a tinyconfig boot.

### PL011 in config fragments

Bootability fragments (`tinyconfig`, `allnoconfig`, `rand500config`,
`randdefconfig`) currently pin `CONFIG_SERIAL_8250=y`. arm64/virt needs
`CONFIG_SERIAL_AMBA_PL011=y` instead. Both sets are added to each fragment;
`olddefconfig` discards options not selectable on the current arch, so
adding PL011 options is harmless on x86 and essential on arm64.

### arm64 VM uses 3× timeout and 1 G RAM

Two issues observed on the first tinyconfig/arm64 boot:

1. **Timeout**: TCG software emulation is ~5× slower than KVM. 17/21 tests ran in
   60 s; the remaining 4 were cut off. `VM_TIMEOUT = TIMEOUT × 3` (default 180 s).

2. **OOM during signal busyloop**: `160_signal` spawns `sh -c 'while true; do true;
   done' &`. On arm64/virt with 512 M, this process hit the OOM killer at ~485 MiB
   anon-rss. Root cause: arm64 address-space / COW fault behaviour means a newly
   forked sh process touches a large fraction of the parent's mapped pages in a tight
   loop. Increasing VM memory to 1 G gives sufficient headroom.

Both adjustments are applied automatically in vm.sh when `ARCH == arm64` and do
not affect x86 boot times or memory allocation.

### `localconfig` is x86_64-only

`localconfig` sources `/proc/config.gz` from the running host kernel (a Manjaro
x86_64 machine). Attempting an arm64 build from that config would produce an
unusable image. `build.sh` now dies early if `localconfig` is requested with
`ARCH != x86_64`.

### Default ARCHS unchanged

`ARCHS ?= x86_64 i386` stays the default. arm64 requires `aarch64-linux-gnu-gcc`
(not installed by default on all systems). Users opt in with:
`make all ARCHS="x86_64 i386 arm64"`. After `make bootstrap`, all three work.

### Bootable configs on arm64

All bootable configs work on arm64 given the PL011 fragment additions:
- `defconfig` — arm64 defconfig ships with PL011 enabled; fragment redundant but harmless
- `tinyconfig`, `allnoconfig` — PL011 added via fragment
- `kunitconfig` — defconfig base; same as defconfig
- `rand500config`, `randdefconfig` — fragments ensure PL011 + bootability

---

## Testing

```sh
# Build and boot arm64 only
make all NO_FETCH=1 ARCHS=arm64 CONFIGS="tinyconfig defconfig"

# Full three-arch run
make all NO_FETCH=1 ARCHS="x86_64 i386 arm64"

# Check vm.status for arm64
grep -E 'BOOT|TESTS' build/defconfig-arm64/vm.status
```
