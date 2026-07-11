#!/bin/bash
# Install a built kernel to /boot for Arch/Manjaro (mkinitcpio + GRUB).
# Usage: install.sh <config> <arch>
# Called by: make install CONFIGS=<config> ARCHS=<arch>
# Requires: sudo, mkinitcpio, grub-mkconfig
set -euo pipefail
. "$(dirname "$0")/common.sh"

CONFIG=${1:?usage: install.sh <config> <arch>}
ARCH=${2:?usage: install.sh <config> <arch>}

require_env KERNEL_TREE BUILD_DIR

[[ $ARCH == x86_64 ]] || die "install only supports x86_64 (host architecture)"

OUT_DIR="$BUILD_DIR/$CONFIG-$ARCH"
STATUS_FILE="$OUT_DIR/build.status"

[[ -f $STATUS_FILE ]] || \
    die "No build found for $CONFIG/$ARCH — run: make build CONFIGS=$CONFIG ARCHS=$ARCH"
grep -q '^STATUS=PASS' "$STATUS_FILE" || \
    die "Build did not pass for $CONFIG/$ARCH ($(grep '^STATUS=' "$STATUS_FILE" || echo STATUS=UNKNOWN)) — see $OUT_DIR/build.log"

KVER=$(cat "$OUT_DIR/include/config/kernel.release")
BOOT_SUFFIX="${CONFIG}-${ARCH}"     # e.g. localconfig-x86_64
NPROC=$(nproc 2>/dev/null || echo 1)

# ccache: reuse the build cache for the modules compile
CACHE_DIR=${CACHE_DIR:-cache}
export CCACHE_DIR="$PWD/$CACHE_DIR"

info "Kernel version : $KVER"
info "vmlinuz        : /boot/vmlinuz-$BOOT_SUFFIX"
info "Modules        : /lib/modules/$KVER/"
info "Preset         : /etc/mkinitcpio.d/$CONFIG.preset"
info "Initramfs      : /boot/initramfs-$BOOT_SUFFIX.img"

# ── Step 1: build modules ─────────────────────────────────────────────────────
info "Building modules ($NPROC jobs)..."
make -C "$KERNEL_TREE" \
    O="$PWD/$OUT_DIR" \
    ARCH="$ARCH" \
    CC="ccache gcc" \
    HOSTCC="ccache gcc" \
    -j"$NPROC" \
    modules

# ── Step 2: install modules ───────────────────────────────────────────────────
info "Installing modules to /lib/modules/$KVER/ (sudo)..."
sudo make -C "$KERNEL_TREE" \
    O="$PWD/$OUT_DIR" \
    ARCH="$ARCH" \
    modules_install

# ── Step 3: copy kernel image and System.map ──────────────────────────────────
info "Copying kernel to /boot/vmlinuz-$BOOT_SUFFIX (sudo)..."
sudo cp "$OUT_DIR/arch/x86/boot/bzImage" "/boot/vmlinuz-$BOOT_SUFFIX"
sudo cp "$OUT_DIR/System.map"            "/boot/System.map-$BOOT_SUFFIX"

# ── Step 4: create mkinitcpio preset (Manjaro style) ─────────────────────────
info "Writing /etc/mkinitcpio.d/$CONFIG.preset (sudo)..."
sudo tee "/etc/mkinitcpio.d/$CONFIG.preset" > /dev/null <<EOF
# mkinitcpio preset for kernel-test '$CONFIG' profile
# Kernel version: $KVER

ALL_kver="/boot/vmlinuz-$BOOT_SUFFIX"

PRESETS=('default')

default_image="/boot/initramfs-$BOOT_SUFFIX.img"
EOF

# ── Step 5: generate initramfs ────────────────────────────────────────────────
info "Generating initramfs (sudo mkinitcpio -p $CONFIG)..."
sudo mkinitcpio -p "$CONFIG"

# ── Step 6: update GRUB ───────────────────────────────────────────────────────
info "Updating GRUB (sudo grub-mkconfig)..."
sudo grub-mkconfig -o /boot/grub/grub.cfg

# ── Summary ───────────────────────────────────────────────────────────────────
info "Install complete: $CONFIG / $ARCH  ($KVER)"
info ""
info "GRUB saved default (unchanged — existing kernel stays default):"
sudo grub-editenv list 2>/dev/null || true
info ""
info "Reboot and select 'localconfig-x86_64' from the GRUB menu to test."
info ""
info "To remove this kernel later:"
info "  sudo rm /boot/vmlinuz-$BOOT_SUFFIX /boot/initramfs-$BOOT_SUFFIX.img \\"
info "          /boot/System.map-$BOOT_SUFFIX /etc/mkinitcpio.d/$CONFIG.preset"
info "  sudo rm -rf /lib/modules/$KVER/"
info "  sudo grub-mkconfig -o /boot/grub/grub.cfg"
