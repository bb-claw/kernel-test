# boot_canary

Raw-UART boot marker for classifying "no output" vs "little output" vs
"never got that far" during boot, independent of printk/console state.

## Important: build this IN, not as a loadable module

`early_initcall()` only has meaning for code **built into the kernel**.
If `boot_canary.c` is compiled as a loadable `.ko` and inserted with
`insmod` (e.g. from your initramfs init script), the "early_initcall"
attribute is discarded and it just runs at normal module-load time —
i.e. late, after console is already up. That defeats the entire point.

For this to actually run before `console_init()`, add it to the
kernel source tree and build it in (`=y`, not `=m`):

1. Drop `boot_canary.c` into `drivers/misc/` (or any built-in-friendly
   location in your kernel-test tree's source).
2. Add to `drivers/misc/Makefile`:
   ```
   obj-$(CONFIG_BOOT_CANARY) += boot_canary.o
   ```
3. Add to `drivers/misc/Kconfig`:
   ```
   config BOOT_CANARY
       bool "Raw UART boot canary for early-boot diagnostics"
       default n
       help
         Writes a fixed marker directly to the UART from early_initcall,
         bypassing printk/console, to distinguish "never reached this
         point" from "reached it but produced no visible output".
   ```
4. Enable it in the configs your test matrix builds: `CONFIG_BOOT_CANARY=y`.

The Makefile in this directory (`make` against `KDIR`) is included for
quick standalone compile-testing of the C file's syntax against a
given kernel tree's headers — it produces a loadable `.ko`, which is
fine for confirming it compiles, but again: for the early-initcall
behavior you actually want, it has to be built in.

## Notes on portability

- Hardcoded to I/O port `0x3f8` (x86 COM1 / QEMU `-serial stdio`
  default). For non-x86 targets or a different UART, replace the
  `inb`/`outb` pair with the appropriate MMIO read/write for that
  platform's UART (e.g. `readl`/`writel` against an `ioremap()`'d
  address — though `ioremap()` may itself be too late for very early
  init; a fixed physical address with `early_ioremap()` is the usual
  workaround for ARM/other MMIO-UART platforms).
- If QEMU isn't passed `-serial stdio` (or equivalent), this writes
  into the void — same as any other boot output, but worth double
  checking in your harness's QEMU invocation.

## Next steps (per the earlier roadmap)

1. **This step**: prove "reached early_initcall" independent of console.
2. Add an initcall-level counter so each stage logs its own reach-point.
3. Add a panic notifier flushing state through the same raw path.
4. Consider `pstore`/`ramoops` for surviving hard hangs, not just clean panics.
