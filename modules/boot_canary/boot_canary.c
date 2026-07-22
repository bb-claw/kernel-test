// SPDX-License-Identifier: GPL-2.0
/*
 * boot_canary.c — write a fixed marker directly to the UART from
 * early_initcall, bypassing printk/console entirely.
 *
 * Purpose: distinguish "kernel never reached early_initcall" from
 * "kernel reached it but produced no console output."
 *
 * Architecture support:
 *   x86 / i386 — 16550 UART via I/O ports  (COM1 at 0x3f8)
 *   arm64       — PL011 UART via MMIO  (QEMU virt board: 0x09000000)
 *
 * IMPORTANT: must be built into the kernel (=y), not loaded as .ko.
 * early_initcall() is silently demoted to module_init() for loadable
 * modules — the function then runs after console_init() and loses all
 * diagnostic value.  Drop this file into drivers/misc/ and set
 * CONFIG_BOOT_CANARY=y.  The Makefile in this directory is only for
 * syntax-checking the C file against a kernel tree's headers.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/delay.h>

/* CRLF prefix guarantees a clean line start on any serial terminal */
static const char canary_msg[] = "\r\n[BOOT_CANARY] early_initcall reached\r\n";

/* ── x86 / i386 — 16550 UART via I/O ports ──────────────────────── */
#ifdef CONFIG_X86

#define UART_BASE     0x3f8
#define UART_THR      0x00
#define UART_LSR      0x05
#define UART_LSR_THRE 0x20

static void canary_putc(char c)
{
	int timeout = 100000;

	while (!(inb(UART_BASE + UART_LSR) & UART_LSR_THRE) && --timeout)
		udelay(1);
	if (!timeout)
		return;		/* UART stuck — skip byte, don't write to busy TX */
	outb(c, UART_BASE + UART_THR);
}

static void arch_canary_write(const char *s)
{
	while (*s)
		canary_putc(*s++);
}

/* ── arm64 — PL011 UART via MMIO ────────────────────────────────── */
#elif defined(CONFIG_ARM64)

#define PL011_BASE    0x09000000UL	/* QEMU virt machine UART */
#define PL011_UARTDR  0x000		/* Data Register (write = TX) */
#define PL011_UARTFR  0x018		/* Flag Register */
#define PL011_FR_TXFF BIT(5)		/* TX FIFO full */

static void pl011_putc(void __iomem *base, char c)
{
	int timeout = 100000;

	while ((readw(base + PL011_UARTFR) & PL011_FR_TXFF) && --timeout)
		udelay(1);
	if (!timeout)
		return;		/* UART stuck — skip byte */
	writeb(c, base + PL011_UARTDR);
}

static void arch_canary_write(const char *s)
{
	void __iomem *base = ioremap(PL011_BASE, 0x1000);

	if (!base)
		return;
	while (*s)
		pl011_putc(base, *s++);
	iounmap(base);
}

#endif /* arch */

/* ── initcall ─────────────────────────────────────────────────────── */

static int __init boot_canary_init(void)
{
#if defined(CONFIG_X86) || defined(CONFIG_ARM64)
	/*
	 * Raw UART write — fires even with zero console drivers registered.
	 * If this appears but the pr_info below does not: printk is broken.
	 * If neither appears: kernel never reached early_initcall.
	 */
	arch_canary_write(canary_msg);
#endif
	pr_info("boot_canary: early_initcall reached (printk path)\n");
	return 0;
}

/* No-op exit so the .ko can be cleanly unloaded during syntax testing */
static void __exit boot_canary_exit(void) {}

early_initcall(boot_canary_init);
module_exit(boot_canary_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Benjamin Boortz <bennib@mailbox.org>");
MODULE_DESCRIPTION("Raw UART boot canary — reports early_initcall reach independent of console state");
