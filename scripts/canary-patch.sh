#!/bin/bash
# Patch KERNEL_TREE/drivers/misc/ with built-in diagnostic modules.
#
# Copies module sources from modules/, then adds obj- entries to
# drivers/misc/Makefile and config stanzas to drivers/misc/Kconfig.
# All operations are idempotent — safe to run multiple times.
#
# Usage:
#   make canary-patch [KERNEL_TREE=~/git/linux]
#   KERNEL_TREE=~/git/linux scripts/canary-patch.sh
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULES_DIR="$REPO_DIR/modules"
KERNEL_TREE="${KERNEL_TREE:-${HOME}/git/linux}"
MISC_DIR="$KERNEL_TREE/drivers/misc"

[[ -d "$MISC_DIR" ]] \
    || die "drivers/misc not found — set KERNEL_TREE (current: $KERNEL_TREE)"

# ── Copy module sources (overwrite silently) ──────────────────────────────────

for mod_dir in "$MODULES_DIR"/*/; do
    mod_name="$(basename "$mod_dir")"
    src="$mod_dir/${mod_name}.c"
    if [[ ! -f "$src" ]]; then
        info "skip: $mod_name — no ${mod_name}.c in $mod_dir"
        continue
    fi
    cp "$src" "$MISC_DIR/${mod_name}.c"
    info "copy: $mod_name.c → $MISC_DIR/"
done

# ── Patch drivers/misc/Makefile (idempotent) ──────────────────────────────────

MISC_MK="$MISC_DIR/Makefile"

add_makefile_entry() {
    local entry="$1"
    if grep -qF "$entry" "$MISC_MK"; then
        info "ok:   already in Makefile: $entry"
    else
        printf '%s\n' "$entry" >> "$MISC_MK"
        info "add:  Makefile: $entry"
    fi
}

add_makefile_entry 'obj-$(CONFIG_BOOT_CANARY) += boot_canary.o'
add_makefile_entry 'obj-$(CONFIG_DEBUG_42)    += debug_42.o'

# ── Patch drivers/misc/Kconfig (idempotent) ───────────────────────────────────

MISC_KC="$MISC_DIR/Kconfig"

add_kconfig_entry() {
    local sym="$1" desc="$2" help="$3"

    if grep -q "^config ${sym}$" "$MISC_KC"; then
        info "ok:   already in Kconfig: config $sym"
        return
    fi

    local entry
    entry=$(printf 'config %s\n\tbool "%s"\n\tdefault n\n\thelp\n\t  %s\n' \
        "$sym" "$desc" "$help")

    # Insert before the last 'endmenu' so the entry stays inside the menu
    local last_endmenu
    last_endmenu=$(grep -n '^endmenu$' "$MISC_KC" | tail -1 | cut -d: -f1)
    if [[ -n "$last_endmenu" ]]; then
        local tmp
        tmp=$(mktemp)
        head -n "$(( last_endmenu - 1 ))" "$MISC_KC" > "$tmp"
        printf '\n%s\n\n' "$entry" >> "$tmp"
        tail -n "+${last_endmenu}" "$MISC_KC" >> "$tmp"
        mv "$tmp" "$MISC_KC"
    else
        printf '\n%s\n' "$entry" >> "$MISC_KC"
    fi
    info "add:  Kconfig: config $sym"
}

add_kconfig_entry "BOOT_CANARY" \
    "Raw UART boot canary for early-boot diagnostics" \
    "Writes a marker to the UART from early_initcall, bypassing printk, to
	  diagnose silent kernel boots. x86/i386: COM1 I/O port (0x3f8). arm64:
	  PL011 MMIO at 0x09000000 (QEMU virt). The kernel-test harness detects
	  the [BOOT_CANARY] marker in serial output when CANARY=1."

add_kconfig_entry "DEBUG_42" \
    "Debug /proc entry returning 42 (boot verification)" \
    "Creates /proc/debug_42 at module_init time. The kernel-test harness
	  reads it via test 250_debug-42 to confirm procfs is operational.
	  Has no side effects; safe to leave enabled in test kernels."

printf '\n'
info "kernel tree patched: $KERNEL_TREE"
info "rebuild with CANARY=1: make canary-patch && make all NO_FETCH=1 CANARY=1 CONFIGS=tinyconfig"
