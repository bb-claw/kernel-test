#!/bin/bash
# Install all dependencies required to run the kernel-test harness.
# Detects the distribution and uses the appropriate package manager.
# Idempotent — safe to run multiple times.
# Usage: make bootstrap
set -euo pipefail
. "$(dirname "$0")/common.sh"

# ── Distro / package-manager detection ───────────────────────────────────────

detect_pm() {
    if   command -v pacman  &>/dev/null; then echo pacman
    elif command -v apt-get &>/dev/null; then echo apt
    elif command -v dnf     &>/dev/null; then echo dnf
    elif command -v zypper  &>/dev/null; then echo zypper
    else echo unknown
    fi
}

PM=$(detect_pm)
info "Detected package manager: $PM"

# ── Install packages ──────────────────────────────────────────────────────────

install_packages() {
    case "$PM" in

        pacman)
            # gcc-multilib replaces gcc and adds 32-bit support for i386 kernel builds.
            # Remove gcc first if present to avoid the conflict.
            if pacman -Q gcc &>/dev/null && ! pacman -Q gcc-multilib &>/dev/null; then
                info "Replacing gcc with gcc-multilib for i386 support"
                sudo pacman -S --needed --noconfirm gcc-multilib
            fi
            sudo pacman -S --needed --noconfirm \
                gcc-multilib make ccache \
                qemu-system-x86 \
                cpio git \
                bc flex bison libelf pahole
            ;;

        apt)
            sudo apt-get update -qq
            sudo apt-get install -y \
                gcc gcc-multilib make ccache \
                qemu-system-x86 \
                cpio git \
                bc flex bison libelf-dev dwarves
            ;;

        dnf)
            sudo dnf install -y \
                gcc gcc-multilib make ccache \
                qemu-system-x86 \
                cpio git \
                bc flex bison elfutils-libelf-devel dwarves
            ;;

        zypper)
            sudo zypper install -y \
                gcc gcc-multilib make ccache \
                qemu-x86 \
                cpio git \
                bc flex bison libelf-devel dwarves
            ;;

        unknown)
            die "No supported package manager found. Install packages manually — see README.md."
            ;;
    esac
}

info "Installing packages..."
install_packages

# ── Toybox: download static binaries for each arch ───────────────────────────

TOYBOX_VERSION=${TOYBOX_VERSION:-0.8.9}
CACHE_DIR=${CACHE_DIR:-cache}
TOYBOX_BASE_URL="https://www.landley.net/toybox/downloads/binaries/${TOYBOX_VERSION}"

download_toybox() {
    mkdir -p "$CACHE_DIR"
    local -a arches=(x86_64 i686)
    for ta in "${arches[@]}"; do
        local dest="$CACHE_DIR/toybox-${ta}"
        if [[ -f $dest && -x $dest ]]; then
            info "toybox-${ta} already cached: $dest"
            continue
        fi
        local url="${TOYBOX_BASE_URL}/toybox-${ta}"
        info "Downloading toybox-${ta} ${TOYBOX_VERSION}..."
        if command -v curl &>/dev/null; then
            curl -fsSL --output "$dest" "$url" \
                || die "Download failed: $url — check network or TOYBOX_VERSION=$TOYBOX_VERSION"
        elif command -v wget &>/dev/null; then
            wget -q --output-document="$dest" "$url" \
                || die "Download failed: $url — check network or TOYBOX_VERSION=$TOYBOX_VERSION"
        else
            die "Neither curl nor wget found — cannot download Toybox"
        fi
        chmod +x "$dest"
        info "Cached: $dest"
    done
}

check_toybox() {
    local ok=1
    for ta in x86_64 i686; do
        local dest="$CACHE_DIR/toybox-${ta}"
        if [[ -f $dest && -x $dest ]]; then
            info "toybox-${ta}: OK  ($dest)"
        else
            warn "toybox-${ta}: MISSING — run: make bootstrap"
            ok=0
        fi
    done
    [[ $ok -eq 1 ]]
}

info "Downloading Toybox ${TOYBOX_VERSION} static binaries..."
download_toybox
check_toybox || warn "Toybox binary missing — initramfs builds will fail"

# ── KVM access ────────────────────────────────────────────────────────────────

setup_kvm() {
    if [[ ! -e /dev/kvm ]]; then
        warn "/dev/kvm not found — hardware virtualisation may be disabled in BIOS/UEFI"
        warn "Tests will run in TCG (software) mode — expect 5–10× slower boot"
        return
    fi

    if groups | grep -qw kvm; then
        info "User '$USER' is already in the kvm group"
    else
        info "Adding '$USER' to the kvm group..."
        sudo usermod -aG kvm "$USER"
        warn "Group change takes effect on next login. To apply now without logout:"
        warn "  newgrp kvm"
    fi
}

setup_kvm

# ── gcc -m32 sanity check (i386 kernel builds) ───────────────────────────────

if printf 'int main(){}' | gcc -m32 -x c - -o /dev/null 2>/dev/null; then
    info "gcc -m32: OK (i386 kernel builds supported)"
else
    warn "gcc -m32 failed — i386 kernel builds will not work"
    warn "On Arch: sudo pacman -S gcc-multilib lib32-glibc"
    warn "Continuing with x86_64 only: make ARCHS=x86_64"
fi

# ── Verify all required tools are present ────────────────────────────────────

REQUIRED=(gcc make ccache qemu-system-x86_64 qemu-system-i386 cpio git bc flex bison)
missing=0
info "Checking required tools:"
for cmd in "${REQUIRED[@]}"; do
    path=$(command -v "$cmd" 2>/dev/null || true)
    if [[ -n $path ]]; then
        printf '  %-26s %s\n' "$cmd" "$path"
    else
        printf '  %-26s MISSING\n' "$cmd"
        missing=$((missing + 1))
    fi
done

# pahole is optional but strongly recommended — provides BTF/debug info for recent kernels.
# It is the binary name on all distros (package is called 'pahole' on Arch, 'dwarves' on Debian).
cmd=pahole
command -v "$cmd" &>/dev/null && \
    printf '  %-26s %s  (optional)\n' "$cmd" "$(command -v "$cmd")" || \
    printf '  %-26s missing (optional — needed for BTF/debug info in recent kernels)\n' "$cmd"

echo ""

if [[ $missing -gt 0 ]]; then
    die "$missing required tool(s) still missing after bootstrap — see warnings above"
fi

# ── Git hooks ────────────────────────────────────────────────────────────────

setup_hooks() {
    local hooks_dir="$REPO_ROOT/.githooks"
    if [[ -d $hooks_dir ]]; then
        git -C "$REPO_ROOT" config core.hooksPath .githooks
        info "Git hooks activated (core.hooksPath = .githooks)"
    else
        warn ".githooks/ not found — skipping hook setup"
    fi
}

REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n $REPO_ROOT ]]; then setup_hooks; else warn "Not inside a git repo — skipping hook setup"; fi

# ── Done ─────────────────────────────────────────────────────────────────────

info "Bootstrap complete. Suggested next steps:"
printf '\n'
printf '  # Clone the upstream kernel tree (skip if you already have one)\n'
printf '  git clone --depth=1 \\\n'
printf '    https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \\\n'
printf '    ~/git/linux\n'
printf '\n'
printf '  # Quick single-config smoke test\n'
printf '  make build initramfs test report \\\n'
printf '    KERNEL_TREE=~/git/linux CONFIGS=defconfig ARCHS=x86_64\n'
printf '\n'
printf '  # Full pipeline\n'
printf '  make KERNEL_TREE=~/git/linux\n'
