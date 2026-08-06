#!/bin/bash
# Boot one (config, arch) kernel in QEMU/KVM, capture serial output, detect
# pass/fail, and write build/<config>-<arch>/vm.status.
# Usage: vm.sh <config> <arch>
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/lib/common.sh"

CONFIG=${1:?usage: vm.sh <config> <arch>}
ARCH=${2:?usage: vm.sh <config> <arch>}

require_env BUILD_DIR TIMEOUT

OUT_DIR="$BUILD_DIR/$CONFIG-$ARCH"
INITRAMFS="$BUILD_DIR/initramfs-$ARCH.cpio.gz"
DMESG_FILE="$OUT_DIR/dmesg.txt"
QEMU_LOG="$OUT_DIR/qemu.log"
STATUS_FILE="$OUT_DIR/vm.status"

# ── Architecture-specific settings ───────────────────────────────────────────
# KVM is only available when the guest ISA matches the host; arm64/riscv run
# in TCG (software emulation) on x86 hosts — expect ~5× slower boots.
# TCG arches get 2× timeout and 1 G RAM: COW fork OOMs in 512 M on arm64.
# x86 earlycon uses an explicit COM1 address; bare earlycon silently breaks
# when CONFIG_SERIAL_EARLYCON=y but CONFIG_ACPI=n.

case "$ARCH" in
    x86_64)
        QEMU=qemu-system-x86_64
        QEMU_MACHINE=q35
        KERNEL_IMAGE="$OUT_DIR/arch/x86/boot/bzImage"
        CONSOLE=ttyS0
        EARLYCON="earlycon=uart8250,io,0x3f8"
        QEMU_CPU_FLAGS=()
        if [[ -r /dev/kvm ]]; then
            KVM_FLAGS=(-enable-kvm); VM_TIMEOUT=$TIMEOUT
        else
            warn "KVM not available — running in TCG mode (expect slow boot)"
            KVM_FLAGS=(); VM_TIMEOUT=$(( TIMEOUT * 2 ))
        fi
        VM_MEM=512M
        ;;
    i386)
        QEMU=qemu-system-i386
        QEMU_MACHINE=pc
        KERNEL_IMAGE="$OUT_DIR/arch/x86/boot/bzImage"
        CONSOLE=ttyS0
        EARLYCON="earlycon=uart8250,io,0x3f8"
        QEMU_CPU_FLAGS=()
        if [[ -r /dev/kvm ]]; then
            KVM_FLAGS=(-enable-kvm); VM_TIMEOUT=$TIMEOUT
        else
            warn "KVM not available — running in TCG mode (expect slow boot)"
            KVM_FLAGS=(); VM_TIMEOUT=$(( TIMEOUT * 2 ))
        fi
        VM_MEM=512M
        ;;
    arm64)
        QEMU=qemu-system-aarch64
        QEMU_MACHINE=virt
        KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/Image"
        CONSOLE=ttyAMA0
        EARLYCON="earlycon"
        QEMU_CPU_FLAGS=(-cpu cortex-a57)
        warn "arm64: KVM not used on x86 host — running in TCG mode (expect slow boot)"
        KVM_FLAGS=()
        VM_TIMEOUT=$(( TIMEOUT * 2 ))
        VM_MEM=1G
        ;;
    riscv)
        QEMU=qemu-system-riscv64
        QEMU_MACHINE=virt
        KERNEL_IMAGE="$OUT_DIR/arch/riscv/boot/Image"
        CONSOLE=ttyS0
        EARLYCON="earlycon"
        QEMU_CPU_FLAGS=()
        warn "riscv: KVM not used on x86 host — running in TCG mode (expect slow boot)"
        KVM_FLAGS=()
        VM_TIMEOUT=$(( TIMEOUT * 2 ))
        VM_MEM=1G
        ;;
    *)
        die "Unsupported arch: $ARCH"
        ;;
esac

# ── Boot the kernel ───────────────────────────────────────────────────────────

info "Booting $CONFIG / $ARCH (timeout: ${VM_TIMEOUT}s)"

VM_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VM_START_EPOCH=$(date -u +%s)

QEMU_EXIT=0
timeout "$VM_TIMEOUT" "$QEMU" \
    "${KVM_FLAGS[@]}" \
    "${QEMU_CPU_FLAGS[@]}" \
    -M "$QEMU_MACHINE" \
    -m "$VM_MEM" \
    -display none \
    -no-reboot \
    -kernel "$KERNEL_IMAGE" \
    -initrd "$INITRAMFS" \
    -append "console=$CONSOLE ${EARLYCON} panic=5 quiet" \
    -serial "file:$DMESG_FILE" \
    > /dev/null 2> "$QEMU_LOG" \
    || QEMU_EXIT=$?

VM_DURATION=$(( $(date -u +%s) - VM_START_EPOCH ))

# ── Parse, evaluate, record, and report ──────────────────────────────────────

parse_serial_output   "$DMESG_FILE"
determine_boot_status "$DMESG_FILE" "$QEMU_EXIT" 0
write_run_status      "$STATUS_FILE" "$VM_START_TIME" "$VM_DURATION"

if ! log_run_result "$CONFIG / $ARCH"; then
    # CANARY diagnostics on boot failure only (not on partial test failures).
    if [[ "${CANARY:-0}" == 1 && "$BOOT_STATUS" == FAIL ]]; then
        if [[ "${CANARY_EARLY:-}" == reached ]]; then
            warn "CANARY: early_initcall reached — kernel ran but console/earlycon produced no output"
        else
            warn "CANARY: [BOOT_CANARY] not found — kernel did not reach early_initcall"
        fi
    fi
    exit 1
fi

if [[ "${CANARY:-0}" == 1 && "${CANARY_EARLY:-}" == missing && "$BOOT_STATUS" == PASS ]]; then
    warn "CANARY: [BOOT_CANARY] not found despite successful boot — CONFIG_BOOT_CANARY may not be built in (run 'make canary-patch' first)"
fi
