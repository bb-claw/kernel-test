#!/bin/bash
# Install a built kernel to /boot for Arch/Manjaro (mkinitcpio + GRUB).
# Usage: install.sh <config> <arch>
# Called by: make install CONFIGS=<config> ARCHS=<arch>
# Requires: sudo, mkinitcpio, grub-mkconfig; dkms (optional, for out-of-tree modules)
set -euo pipefail
. "$(dirname "$0")/common.sh"

CONFIG=${1:?usage: install.sh <config> <arch>}
ARCH=${2:?usage: install.sh <config> <arch>}

require_env KERNEL_TREE BUILD_DIR
GCC=${GCC:-gcc}

[[ $ARCH == x86_64 ]] || die "install only supports x86_64 (host architecture)"

OUT_DIR="$BUILD_DIR/$CONFIG-$ARCH"
STATUS_FILE="$OUT_DIR/build.status"

[[ -f $STATUS_FILE ]] || \
    die "No build found for $CONFIG/$ARCH — run: make build CONFIGS=$CONFIG ARCHS=$ARCH"
grep -q '^STATUS=PASS' "$STATUS_FILE" || \
    die "Build did not pass for $CONFIG/$ARCH ($(grep '^STATUS=' "$STATUS_FILE" || echo STATUS=UNKNOWN)) — see $OUT_DIR/build.log"

# Use the kernel tree recorded at build time so 'make install' works without
# re-specifying STABLE_RELEASE or KERNEL_TREE on the command line.
BUILT_TREE=$(grep '^KERNEL_TREE=' "$STATUS_FILE" | cut -d= -f2-)
[[ -n $BUILT_TREE ]] && KERNEL_TREE="$BUILT_TREE"

KVER=$(cat "$OUT_DIR/include/config/kernel.release")
BOOT_SUFFIX="${CONFIG}-${ARCH}"     # e.g. localconfig-x86_64
NPROC=$(nproc 2>/dev/null || echo 1)

# ccache: reuse the build cache for the modules compile
CACHE_DIR=${CACHE_DIR:-cache}
export CCACHE_DIR="$PWD/$CACHE_DIR"

info "Kernel version : $KVER"
info "vmlinuz        : /boot/vmlinuz-$BOOT_SUFFIX"
info "Modules        : /lib/modules/$KVER/"
info "mkinitcpio conf: /etc/mkinitcpio.d/$CONFIG.conf  (system conf, MODULES cleared)"
info "Preset         : /etc/mkinitcpio.d/$CONFIG.preset"
info "Initramfs      : /boot/initramfs-$BOOT_SUFFIX.img"

# ── Step 1: build modules ─────────────────────────────────────────────────────
info "Building modules ($NPROC jobs)..."
make -C "$KERNEL_TREE" \
    O="$PWD/$OUT_DIR" \
    ARCH="$ARCH" \
    CC="ccache $GCC" \
    HOSTCC="ccache $GCC" \
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

# ── Step 4: create mkinitcpio conf and preset (Manjaro style) ────────────────
# Write a per-kernel mkinitcpio conf derived from the system default but with
# MODULES cleared — the autodetect hook selects in-tree modules automatically;
# DKMS out-of-tree modules (nvidia, vbox, …) are installed in step 5.
CONF_FILE="/etc/mkinitcpio.d/$CONFIG.conf"
info "Writing $CONF_FILE (sudo)..."
sudo bash -c "sed 's/^MODULES=.*/MODULES=()/' /etc/mkinitcpio.conf > '$CONF_FILE'"

info "Writing /etc/mkinitcpio.d/$CONFIG.preset (sudo)..."
sudo tee "/etc/mkinitcpio.d/$CONFIG.preset" > /dev/null <<EOF
# mkinitcpio preset for kernel-test '$CONFIG' profile
# Kernel version: $KVER

ALL_kver="/boot/vmlinuz-$BOOT_SUFFIX"
ALL_config="$CONF_FILE"

PRESETS=('default')

default_image="/boot/initramfs-$BOOT_SUFFIX.img"
EOF

# ── Step 4b: sysrq override ──────────────────────────────────────────────────
# systemd's /usr/lib/sysctl.d/50-default.conf sets kernel.sysrq=16 (sync only)
# at boot, overriding the kernel compile-time default of 1.
# Write a higher-priority override so REISUB works for emergency recovery.
info "Writing /etc/sysctl.d/99-sysrq.conf (sudo)..."
sudo tee /etc/sysctl.d/99-sysrq.conf > /dev/null <<'SYSCTL'
# Enable all Magic SysRq keys (including REISUB safe reboot).
# Overrides /usr/lib/sysctl.d/50-default.conf which restricts to 16 (sync only).
kernel.sysrq = 1
SYSCTL

# ── Step 5: build DKMS modules ───────────────────────────────────────────────
# Must run after modules_install and before mkinitcpio so out-of-tree modules
# (nvidia, virtualbox, …) land in /lib/modules/$KVER/ before the initramfs is
# generated.
if command -v dkms &>/dev/null; then
    info "Building DKMS modules for $KVER (sudo dkms autoinstall)..."
    sudo dkms autoinstall -k "$KVER" || warn "dkms autoinstall had failures — X11/GPU drivers may not work"
else
    warn "dkms not found — skipping DKMS build (nvidia etc. will not be available)"
fi

# ── Step 6: generate initramfs ────────────────────────────────────────────────
info "Generating initramfs (sudo mkinitcpio -p $CONFIG)..."
sudo mkinitcpio -p "$CONFIG"

# ── Step 7: update GRUB ───────────────────────────────────────────────────────
info "Updating GRUB (sudo grub-mkconfig)..."
sudo grub-mkconfig -o /boot/grub/grub.cfg

# ── Step 8: sanity checks ────────────────────────────────────────────────────
SANITY_FAIL=0

if [[ -f "/boot/initramfs-$BOOT_SUFFIX.img" ]]; then
    info "OK  /boot/initramfs-$BOOT_SUFFIX.img"
else
    warn "MISSING  /boot/initramfs-$BOOT_SUFFIX.img — mkinitcpio may have failed"
    SANITY_FAIL=1
fi

if [[ -f "/boot/vmlinuz-$BOOT_SUFFIX" ]]; then
    info "OK  /boot/vmlinuz-$BOOT_SUFFIX"
else
    warn "MISSING  /boot/vmlinuz-$BOOT_SUFFIX"
    SANITY_FAIL=1
fi

if grep -q "vmlinuz-$BOOT_SUFFIX" /boot/grub/grub.cfg 2>/dev/null; then
    info "OK  vmlinuz-$BOOT_SUFFIX found in grub.cfg"
else
    warn "NOT FOUND in grub.cfg — grub-mkconfig may have failed or boot suffix changed"
    SANITY_FAIL=1
fi

[[ $SANITY_FAIL -ne 0 ]] && warn "One or more sanity checks failed — review output above before rebooting"

# ── Summary ───────────────────────────────────────────────────────────────────
info "Install complete: $CONFIG / $ARCH  ($KVER)"
info ""
info "GRUB grubenv (saved_entry — this is what boots next):"
sudo grub-editenv list 2>/dev/null || true
info ""
info "NOTE: if 'vmlinuz-$BOOT_SUFFIX' sorts before your distro kernel, it becomes"
info "      the simple 'Manjaro Linux' entry and will boot by default."
info "      To pin your previous kernel as default:"
info "        sudo grub-set-default '<Advanced submenu entry ID>'"
info ""
info "Reboot and select '$BOOT_SUFFIX' from the GRUB menu to test."
info ""
info "To remove this kernel later:"
info "  sudo dkms remove --all -k $KVER   # remove DKMS modules first"
info "  sudo rm /boot/vmlinuz-$BOOT_SUFFIX /boot/initramfs-$BOOT_SUFFIX.img \\"
info "          /boot/System.map-$BOOT_SUFFIX \\"
info "          /etc/mkinitcpio.d/$CONFIG.preset /etc/mkinitcpio.d/$CONFIG.conf \\"
info "          /etc/sysctl.d/99-sysrq.conf"
info "  sudo rm -rf /lib/modules/$KVER/"
info "  sudo grub-mkconfig -o /boot/grub/grub.cfg"
