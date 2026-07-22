# Boot Canary — Design Plan

## Problem

Some kernel boots produce zero serial output. QEMU either exits cleanly (exit 0)
or times out, with `dmesg.txt` empty or containing only a few early lines. The
harness cannot distinguish between:

1. Kernel hung before `do_initcalls()` (setup_arch, mm_init, etc.)
2. Kernel ran normally but earlycon/console was not configured
3. QEMU serial pipe broken (misconfigured `-serial` flag)

All three produce the same symptom in `vm.sh`: `FAIL_REASON="No console output"`.
Diagnosing root cause requires a signal that is independent of the printk/console
stack entirely.

## Solution: Two Diagnostic Tiers

### Tier 1 — `boot_canary` (built-in, raw UART)

`drivers/misc/boot_canary.c` registered via `early_initcall()` writes a fixed
ASCII marker directly to the UART hardware, bypassing the kernel's entire
printk → console → serial driver chain.

- **x86 / i386**: `outb()` to COM1 I/O port `0x3f8` (QEMU `-serial stdio` default)
- **arm64**: `ioremap()` + `writeb()` to PL011 at `0x09000000` (QEMU `virt` machine)

`early_initcall()` fires from `do_initcalls()` which runs in the init thread,
after `mm_init()`, `console_init()`, and `setup_arch()` — so `ioremap()` is safe.
It runs before any driver probe or subsystem initcall.

The marker string is `[BOOT_CANARY] early_initcall reached`. The harness greps
for it in the captured serial output and writes `CANARY_EARLY=reached|missing`
to `vm.status`.

### Tier 2 — `debug_42` (built-in, /proc)

`drivers/misc/debug_42.c` registered via `module_init()` creates `/proc/debug_42`
returning `"42\n"`. Test `250_debug-42.sh` cats the file inside the VM.

- Confirms: procfs mounted, VFS working, `module_init()` ran to completion
- Skips gracefully when `CONFIG_DEBUG_42` is not built in (CANARY=1 not used)

## Decision Table

| `[BOOT_CANARY]` in serial | dmesg messages present | Diagnosis |
|---|---|---|
| yes | yes | Normal boot — printk/earlycon working |
| yes | no | Kernel ran past early_initcall; console/earlycon misconfigured |
| no | no | Kernel hung before `do_initcalls()` |
| no | yes | Impossible (printk works → earlycon up → canary would appear) |

`/proc/debug_42` returning `42` additionally confirms procfs and late initcalls
are functional.

## Architecture Notes

**x86 / i386**: I/O port access (`inb`/`outb`) requires no memory mapping.
The 16550 UART at `0x3f8` is always present in QEMU's PC and Q35 machine types.
This path works with zero kernel config for the serial driver.

**arm64**: No I/O ports exist; UART is MMIO. QEMU `virt` machine places a PL011
at physical `0x09000000`. At `early_initcall` time, `ioremap()` is safe because:
- `paging_init()` completed during `setup_arch()`
- vmalloc area initialized before `rest_init()`
- `kmem_cache_init()` (required by `ioremap` internally) done in `mm_init()`

`ioremap` is called and `iounmap`d within the single `arch_canary_write()` call —
no persistent mapping.

## Why `.ko` Does Not Work

`early_initcall()` in a loadable module has no special effect. The module loader
calls `module->init` at `insmod` time, which is equivalent to `module_init()` and
runs after `console_init()`. Loading the `.ko` from `/init` in the initramfs:
- Only fires after the kernel reached `/init` (which the existing `> TEST RUN:`
  markers already confirm)
- Fires after console is initialized, so raw UART and printk fire simultaneously —
  the distinguishing diagnostic is lost

The modules in `modules/` include a `Makefile` for syntax-checking the C code
against a kernel tree's headers. The resulting `.ko` is not used by the harness.

## Mechanism: `make canary-patch`

`scripts/canary-patch.sh` patches the kernel tree once before a CANARY=1 run:

1. Copies `modules/<name>/<name>.c` → `KERNEL_TREE/drivers/misc/<name>.c`
2. Appends `obj-$(CONFIG_BOOT_CANARY) += boot_canary.o` to `drivers/misc/Makefile`
3. Appends `obj-$(CONFIG_DEBUG_42) += debug_42.o` to `drivers/misc/Makefile`
4. Inserts `config BOOT_CANARY` and `config DEBUG_42` stanzas into
   `drivers/misc/Kconfig` (before the final `endmenu`)

All four operations are idempotent. The kernel tree is left patched after the
run (no revert); a subsequent normal `make all` without `CANARY=1` will not
include the canary modules because `CONFIG_BOOT_CANARY` is not in the normal
config fragments.

## Usage

```sh
# One-time kernel tree patch (run once per kernel checkout)
make canary-patch

# Rebuild with canary enabled and boot
make all NO_FETCH=1 CANARY=1 CONFIGS=tinyconfig ARCHS=x86_64

# Check result
grep CANARY_EARLY reports/<latest>/vmstatus-tinyconfig-x86_64.txt

# Single failing config
make all NO_FETCH=1 CANARY=1 \
    CONFIG_FILE=configs/archive_failed/kconfig-tinyconfig-x86_64-...-BOOT_FAIL-no-output.config
```

## Harness Integration

**`lib/build.sh`** (step 1b.2): when `CANARY=1`, appends `configs/canary.config`
(`CONFIG_BOOT_CANARY=y`, `CONFIG_DEBUG_42=y`) to `.config` and runs `olddefconfig`.
Skipped for seed replay (`SEED_CONFIG` set).

**`lib/vm.sh`**: after serial capture, greps `dmesg.txt` for `\[BOOT_CANARY\]`
when `CANARY=1`. Writes `CANARY_EARLY=reached|missing` to `vm.status`. Emits a
`warn` line on FAIL with the canary diagnosis.

**`tests/custom/250_debug-42.sh`**: cats `/proc/debug_42` inside the VM; skips
if absent. Part of the normal test suite — passes on CANARY=1 builds, skips on
normal builds.

## Future Work

- Initcall-level counter: emit separate markers from `pure_initcall`, `core_initcall`,
  `postcore_initcall` to narrow the hang point further
- Panic notifier: flush raw UART state on `panic()` to capture hangs that reach
  the panic path but not the console
- `pstore`/`ramoops`: survive hard hangs that never reach `panic()`
- arm64 firmware UART detection: read QEMU DT to find UART base dynamically
  instead of hardcoding `0x09000000`
