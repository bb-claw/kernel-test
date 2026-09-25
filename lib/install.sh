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

VM_STATUS_FILE="$OUT_DIR/vm.status"
if [[ ! -f $VM_STATUS_FILE ]]; then
    warn "No VM test results for $CONFIG/$ARCH — kernel has not been tested; installing anyway"
else
    vm_boot=$(grep '^BOOT=' "$VM_STATUS_FILE" | cut -d= -f2- || true)
    [[ $vm_boot == PASS ]] || \
        warn "Last VM boot result was '$vm_boot' for $CONFIG/$ARCH — installing anyway"
fi

# Use the kernel tree recorded at build time so 'make install' works without
# re-specifying STABLE_RELEASE or KERNEL_TREE on the command line.
BUILT_TREE=$(grep '^KERNEL_TREE=' "$STATUS_FILE" | cut -d= -f2-)
[[ -n $BUILT_TREE ]] && KERNEL_TREE="$BUILT_TREE"

KVER=$(cat "$OUT_DIR/include/config/kernel.release")
MAJOR_MINOR=$(grep -oE '^[0-9]+\.[0-9]+' <<< "$KVER")

# Derive LABEL if not set by preset (mirrors report.sh auto-detection).
if [[ -z ${LABEL:-} ]]; then
    if [[ -n ${STABLE_RELEASE:-} ]]; then
        LABEL=stable
    elif [[ $KERNEL_TREE == *linux-next* ]]; then
        LABEL=linux-next
    elif [[ $KERNEL_TREE == *stable-rc* ]]; then
        LABEL=stable-rc
    elif [[ ! $KVER =~ -rc ]]; then
        LABEL=stable
    else
        LABEL=mainline
    fi
fi

BOOT_SUFFIX="${CONFIG}-${LABEL}-${MAJOR_MINOR}-${ARCH}"   # e.g. localconfig-mainline-7.2-x86_64
NPROC=$(nproc 2>/dev/null || echo 1)

# ccache: reuse the build cache for the modules compile
CACHE_DIR=${CACHE_DIR:-cache}
export CCACHE_DIR="$PWD/$CACHE_DIR"
ccache --set-config="max_size=${CCACHE_MAX_SIZE:-25G}"
if [[ "${CCACHE_TUNE:-1}" == "1" ]]; then
    ccache --set-config="sloppiness=time_macros"
    ccache --set-config="compression_level=1"
    ccache --set-config="base_dir=$HOME"
else
    ccache --set-config="sloppiness="
    ccache --set-config="compression_level=0"
    ccache --set-config="base_dir="
fi

info "Kernel version : $KVER"
info "vmlinuz        : /boot/vmlinuz-$BOOT_SUFFIX"
info "Modules        : /lib/modules/$KVER/"
info "mkinitcpio conf: /etc/mkinitcpio.d/$BOOT_SUFFIX.conf  (system conf, MODULES cleared)"
info "Preset         : /etc/mkinitcpio.d/$BOOT_SUFFIX.preset"
info "Initramfs      : /boot/initramfs-$BOOT_SUFFIX.img"

# ── Step 1: resolve any config drift silently ─────────────────────────────────
# When the kernel version changes, .config may have invalid symbols or new
# options without defaults. olddefconfig accepts new defaults non-interactively
# so 'make modules' does not fall into interactive oldconfig.
info "Resolving config (olddefconfig)..."
make -C "$KERNEL_TREE" \
    O="$PWD/$OUT_DIR" \
    ARCH="$ARCH" \
    CC="ccache $GCC" \
    HOSTCC="ccache $GCC" \
    olddefconfig

# Update the stored sha256 so report.sh does not flag a false MISMATCH.
# olddefconfig may add new-option defaults or drop stale symbols, changing .config.
NEW_SHA256=$(sha256sum "$PWD/$OUT_DIR/.config" | awk '{print $1}')
sed -i "s/^CONFIG_SHA256=.*/CONFIG_SHA256=$NEW_SHA256/" "$STATUS_FILE"
info "Config SHA256 updated: $NEW_SHA256"

# ── Step 2: build modules ─────────────────────────────────────────────────────
info "Building modules ($NPROC jobs)..."
make -C "$KERNEL_TREE" \
    O="$PWD/$OUT_DIR" \
    ARCH="$ARCH" \
    CC="ccache $GCC" \
    HOSTCC="ccache $GCC" \
    -j"$NPROC" \
    modules

# ── Step 3: install modules ───────────────────────────────────────────────────
info "Installing modules to /lib/modules/$KVER/ (sudo)..."
sudo make -C "$KERNEL_TREE" \
    O="$PWD/$OUT_DIR" \
    ARCH="$ARCH" \
    modules_install

# ── Step 4: copy kernel image and System.map ──────────────────────────────────
info "Copying kernel to /boot/vmlinuz-$BOOT_SUFFIX (sudo)..."
sudo cp "$OUT_DIR/arch/x86/boot/bzImage" "/boot/vmlinuz-$BOOT_SUFFIX"
sudo cp "$OUT_DIR/System.map"            "/boot/System.map-$BOOT_SUFFIX"

# ── Step 5: create mkinitcpio conf and preset (Manjaro style) ────────────────
# Write a per-kernel mkinitcpio conf derived from the system default but with
# MODULES cleared — the autodetect hook selects in-tree modules automatically;
# DKMS out-of-tree modules (nvidia, vbox, …) are installed in step 5.
CONF_FILE="/etc/mkinitcpio.d/$BOOT_SUFFIX.conf"
info "Writing $CONF_FILE (sudo)..."
sudo bash -c "sed 's/^MODULES=.*/MODULES=()/' /etc/mkinitcpio.conf > '$CONF_FILE'"

info "Writing /etc/mkinitcpio.d/$BOOT_SUFFIX.preset (sudo)..."
sudo tee "/etc/mkinitcpio.d/$BOOT_SUFFIX.preset" > /dev/null <<EOF
# mkinitcpio preset for kernel-test '$BOOT_SUFFIX'
# Kernel version: $KVER

ALL_kver="/boot/vmlinuz-$BOOT_SUFFIX"
ALL_config="$CONF_FILE"

PRESETS=('default')

default_image="/boot/initramfs-$BOOT_SUFFIX.img"
EOF

# ── Step 5b: sysrq override ──────────────────────────────────────────────────
# systemd's /usr/lib/sysctl.d/50-default.conf sets kernel.sysrq=16 (sync only)
# at boot, overriding the kernel compile-time default of 1.
# Write a higher-priority override so REISUB works for emergency recovery.
info "Writing /etc/sysctl.d/99-sysrq.conf (sudo)..."
sudo tee /etc/sysctl.d/99-sysrq.conf > /dev/null <<'SYSCTL'
# Enable all Magic SysRq keys (including REISUB safe reboot).
# Overrides /usr/lib/sysctl.d/50-default.conf which restricts to 16 (sync only).
kernel.sysrq = 1
SYSCTL

# ── Step 6: build DKMS modules ───────────────────────────────────────────────
# Must run after modules_install and before mkinitcpio so out-of-tree modules
# (nvidia, virtualbox, …) land in /lib/modules/$KVER/ before the initramfs is
# generated.
if command -v dkms &>/dev/null; then
    info "Building DKMS modules for $KVER (sudo dkms autoinstall)..."
    sudo dkms autoinstall -k "$KVER" || warn "dkms autoinstall had failures — X11/GPU drivers may not work"
else
    warn "dkms not found — skipping DKMS build (nvidia etc. will not be available)"
fi

# ── Step 7: generate initramfs ────────────────────────────────────────────────
info "Generating initramfs (sudo mkinitcpio -p $BOOT_SUFFIX)..."
sudo mkinitcpio -p "$BOOT_SUFFIX"

# ── Step 7b: write persistent GRUB menu entries ───────────────────────────────
# grub-mkconfig derives menu labels from the uname -r string embedded in each
# vmlinuz binary, not the filename. All localconfig kernels share the same
# LOCALVERSION ("-localconfig"), so auto-generated entries are indistinguishable.
# Write /etc/grub.d/06_kernel-test — executed by grub-mkconfig on every run —
# to emit explicit entries labelled with the full filename (e.g. localconfig-stable-rc-7.2-x86_64).
GRUB_SCRIPT=/etc/grub.d/06_kernel-test
info "Writing $GRUB_SCRIPT (sudo)..."
sudo tee "$GRUB_SCRIPT" > /dev/null <<'GRUBSCRIPT'
#!/bin/sh
# kernel-test custom GRUB entries — managed by lib/install.sh; do not edit by hand.
. /etc/default/grub 2>/dev/null || true
ROOT_UUID=$(grub-probe -t fs_uuid / 2>/dev/null || true)
[ -n "$ROOT_UUID" ] || exit 0

for vmlinuz in /boot/vmlinuz-localconfig-*-x86_64; do
    [ -f "$vmlinuz" ] || continue
    suffix="${vmlinuz#/boot/vmlinuz-}"
    initramfs="/boot/initramfs-${suffix}.img"
    [ -f "$initramfs" ] || continue

    printf "menuentry 'kernel-test: %s' --class gnu-linux {\n" "$suffix"
    printf "\tload_video\n"
    printf "\tset gfxpayload=keep\n"
    printf "\tlinux\t%s root=UUID=%s rw %s %s\n" \
        "$vmlinuz" "$ROOT_UUID" \
        "${GRUB_CMDLINE_LINUX_DEFAULT:-}" \
        "${GRUB_CMDLINE_LINUX:-}"
    ucode=
    for _u in /boot/amd-ucode.img /boot/intel-ucode.img; do
        [ -f "$_u" ] && ucode="${ucode:+$ucode }$_u"
    done
    printf "\tinitrd\t%s%s\n" "${ucode:+$ucode }" "$initramfs"
    printf "}\n"
done
GRUBSCRIPT
sudo chmod 755 "$GRUB_SCRIPT"

# ── Step 8: update GRUB ───────────────────────────────────────────────────────
info "Updating GRUB (sudo grub-mkconfig)..."
sudo grub-mkconfig -o /boot/grub/grub.cfg

# ── Step 9: sanity checks ────────────────────────────────────────────────────
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
info "Reboot and select 'vmlinuz-$BOOT_SUFFIX' from the GRUB menu to test."
info ""
info "To remove this kernel later:"
info "  sudo dkms remove --all -k $KVER   # remove DKMS modules first"
info "  sudo rm /boot/vmlinuz-$BOOT_SUFFIX /boot/initramfs-$BOOT_SUFFIX.img \\"
info "          /boot/System.map-$BOOT_SUFFIX \\"
info "          /etc/mkinitcpio.d/$BOOT_SUFFIX.preset /etc/mkinitcpio.d/$BOOT_SUFFIX.conf \\"
info "          /etc/sysctl.d/99-sysrq.conf"
info "  sudo rm -rf /lib/modules/$KVER/"
info "  # Remove GRUB script only when no other kernel-test kernels remain:"
info "  # sudo rm /etc/grub.d/06_kernel-test"
info "  sudo grub-mkconfig -o /boot/grub/grub.cfg"
