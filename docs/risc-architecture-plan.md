# RISC-V Architecture Support — Plan

Branch: `feat/risc-architecture`
Start date: 2026-07-24

---

## Situation

The harness supports x86_64, i386, and arm64. Adding riscv64 extends ISA coverage
to a third family. RISC-V is an open ISA with growing mainline kernel activity; a
number of recent stable patches touch `arch/riscv/`. Like arm64, riscv64 runs in
TCG on an x86 host (no KVM). Test scripts are architecture-agnostic; only the
build/VM/initramfs layers need updating.

---

## Key Differences from x86 and arm64

| Aspect | x86_64 / i386 | arm64 | riscv |
|---|---|---|---|
| Cross-compiler | none / gcc -m32 | `aarch64-linux-gnu-gcc` | `riscv64-linux-gnu-gcc` |
| Kernel ARCH name | `x86` | `arm64` | `riscv` |
| Kernel image | `arch/x86/boot/bzImage` | `arch/arm64/boot/Image` | `arch/riscv/boot/Image` |
| Build target | `bzImage` | `Image` | `Image` |
| QEMU binary | `qemu-system-x86_64` | `qemu-system-aarch64` | `qemu-system-riscv64` |
| QEMU machine | `q35` / `pc` | `virt` | `virt` |
| QEMU CPU flag | (none) | `-cpu cortex-a57` | (none) |
| KVM on x86 host | yes | no (TCG) | no (TCG) |
| Serial console | `ttyS0` (NS16550) | `ttyAMA0` (PL011) | `ttyS0` (NS16550) |
| Toybox binary | `toybox-x86_64` / `toybox-i686` | `toybox-aarch64` | `toybox-riscv64` |

---

## Scope

Files changed:

- `lib/build.sh` — riscv case: `CROSS_COMPILE=riscv64-linux-gnu-`, `KERNEL_IMAGE_NAME=Image`, `BUILD_TIMEOUT×2`
- `lib/vm.sh` — riscv case: `qemu-system-riscv64`, `virt` machine, `ttyS0` console, TCG timeout/RAM scaling
- `lib/initramfs.sh` — add `riscv) TOYBOX_ARCH=riscv64`
- `lib/bootstrap.sh` — `riscv64-linux-gnu-gcc`, `qemu-system-riscv` packages; delegate Toybox download to `lib/download-toybox.sh`
- `lib/download-toybox.sh` — new script: download a single Toybox binary for a given arch; replaces inline download logic in `bootstrap.sh`; idempotent (skips if already cached)
- `configs/*.config` — add `CONFIG_SERIAL_8250=y CONFIG_SERIAL_8250_CONSOLE=y` to bootability fragments for NS16550 support (already present for x86; harmless when arch doesn't select it)

No changes to: test scripts, report.sh, common.sh, checkout.sh, diff.sh.

---

## Design Decisions

### `lib/download-toybox.sh` extraction

`bootstrap.sh` previously embedded the Toybox download loop inline. With four
architectures, the download logic is now a separate script called once per arch.
This also makes it callable from other scripts in the future without sourcing
bootstrap.sh.

### Cross-compiler derived inside build.sh

`CROSS_COMPILE=riscv64-linux-gnu-` is set inside `build.sh` based on `$ARCH`.
The `GCC=` Makefile variable overrides the native host compiler only; riscv always
uses the fixed cross-compiler prefix. Same pattern as arm64.

### KVM skipped for riscv

KVM only accelerates guests whose ISA matches the host. On an x86_64 host, riscv64
must run in TCG (software emulation). `vm.sh` already skips `-enable-kvm` for
arm64; riscv gets the same treatment.

### TCG timeout and RAM

Like arm64, riscv in TCG is slower than KVM. `BUILD_TIMEOUT` is doubled in
`build.sh`. `VM_TIMEOUT` is doubled and RAM set to 1 G in `vm.sh`.

### NS16550 console (ttyS0)

The QEMU `virt` machine for riscv64 exposes an NS16550A UART, not a PL011. The
correct kernel command-line console is `ttyS0`, and the correct earlycon form is
`earlycon=uart8250,mmio,<addr>` or bare `earlycon` (auto-detected from QEMU DT).
This differs from arm64 (`ttyAMA0` / PL011).

### Toybox version bump to 0.8.14

`TOYBOX_VERSION` is bumped from 0.8.9 to 0.8.14 to pick up the riscv64 binary.
The Makefile is the source of truth; scripts receive it via the exported
environment variable. The in-script default matches the Makefile value.

Toybox 0.8.11 introduced two breaking changes that required fixes:

1. **`sh` NOFORK builtin** — `sh script.sh` (bare name) now runs the script
   recursively in the same process ("command recursion"). The inner invocation
   uses a different output path that does not write to the serial console.
   Fix: `/init` calls `/bin/sh "$t"` (full path forces fork+exec). Test scripts
   that fork subshells (`130_fork-exec.sh`) use `/bin/sh -c` for the same reason.

2. **Block-buffered stdout** — stdout switched from line-buffered to
   block-buffered; `printf` output can be lost on abnormal exit. Resolved
   automatically by the fork+exec fix above.

### `localconfig` remains x86_64-only

`localconfig` sources `/proc/config.gz` from the running host kernel. It is not
extended to riscv.

### Default ARCHS updated

`ARCHS ?= x86_64 i386 arm64 riscv` — riscv is added to the default set because
`make bootstrap` installs all prerequisites. Users who have not run `make bootstrap`
since this change must re-run it to get `riscv64-linux-gnu-gcc` and
`qemu-system-riscv64`.

### riscv tinyconfig bootability fragment additions

Two options added to `configs/tinyconfig.config`:

- `CONFIG_FPU=y` — the Toybox riscv64 binary uses floating-point instructions
  in its startup code (crt0). Without FPU support the kernel delivers SIGILL to
  init before it reaches the first echo. Symptoms: `exitcode=0x00000004` panic,
  no `BOOT_OK` in dmesg.

- `CONFIG_SERIAL_OF_PLATFORM=y` — the NS16550 UART on the QEMU virt machine is
  enumerated via device tree. Without this driver the 8250 code never probes the
  DT node, no console device is registered, and init's stdout has nowhere to go.
  Symptoms: "Warning: unable to open an initial console." in dmesg, then silent
  `reboot: Restarting system` with no test output.

### riscv OOM skip in 160_signal.sh

The same COW fork OOM that affects arm64 TCG also affects riscv64 TCG. The
busyloop signal tests skip on `aarch64`; extended to also skip on `riscv64`.

### arch recognition in 050_check-kernel.sh

`uname -m` returns `riscv64`; the arch case statement was extended to include it.

---

## Testing

```sh
# Bootstrap (installs riscv64-linux-gnu-gcc, qemu-system-riscv64, toybox-riscv64)
make bootstrap

# Build and boot riscv only
make all NO_FETCH=1 ARCHS=riscv CONFIGS="tinyconfig defconfig"

# Full four-arch run
make all NO_FETCH=1
```
