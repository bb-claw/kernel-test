#!/bin/bash
# Bisect shortcut: copy bzImage to the existing /boot/vmlinuz-kt-* file only.
# Skips modules, mkinitcpio, and grub-mkconfig — reuses the existing initramfs
# and GRUB entry written by a prior 'make install'.
# Fails if the target file does not already exist (run 'make install' first).
# Usage: install-fast.sh <config> <arch>
set -euo pipefail
. "$(dirname "$0")/common.sh"

CONFIG=${1:?usage: install-fast.sh <config> <arch>}
ARCH=${2:?usage: install-fast.sh <config> <arch>}

require_env KERNEL_TREE BUILD_DIR

[[ $ARCH == x86_64 ]] || die "install-fast only supports x86_64 (host architecture)"

OUT_DIR="$BUILD_DIR/$CONFIG-$ARCH"
BZIMAGE="$OUT_DIR/arch/x86/boot/bzImage"

[[ -f $BZIMAGE ]] || die "No bzImage found at $BZIMAGE — run: make build CONFIGS=$CONFIG ARCHS=$ARCH"

# Reuse KERNEL_TREE from build.status if available.
STATUS_FILE="$OUT_DIR/build.status"
if [[ -f $STATUS_FILE ]]; then
    BUILT_TREE=$(grep '^KERNEL_TREE=' "$STATUS_FILE" | cut -d= -f2- || true)
    [[ -n $BUILT_TREE ]] && KERNEL_TREE="$BUILT_TREE"
fi

# Derive LABEL (mirrors install.sh logic).
KVER=$(cat "$OUT_DIR/include/config/kernel.release" 2>/dev/null || true)
MAJOR_MINOR=$(grep -oE '^[0-9]+\.[0-9]+' <<< "${KVER:-0.0}")
read_kernel_makefile_version > /dev/null || true
KERNEL_FULL_VERSION="${KMV_FULL:-$MAJOR_MINOR}"

if [[ -z ${LABEL:-} ]]; then
    if [[ -n ${STABLE_RELEASE:-} ]]; then
        LABEL=stable
    elif [[ $KERNEL_TREE == *linux-next* ]]; then
        LABEL=linux-next
    elif [[ $KERNEL_TREE == *stable-rc* ]]; then
        LABEL=stable-rc
    elif [[ ! ${KVER:-} =~ -rc ]]; then
        LABEL=stable
    else
        LABEL=mainline
    fi
fi

BOOT_SUFFIX="kt-${CONFIG}-${LABEL}-${KERNEL_FULL_VERSION}-${ARCH}"
TARGET="/boot/vmlinuz-$BOOT_SUFFIX"

if [[ ! -f $TARGET ]]; then
    die "/boot/vmlinuz-$BOOT_SUFFIX does not exist — run 'make install' first to create the GRUB entry and initramfs"
fi

info "install-fast: copying bzImage → $TARGET"
sudo cp "$BZIMAGE" "$TARGET"
info "install-fast: done — reboot and select $BOOT_SUFFIX"
