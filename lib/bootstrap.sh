#!/bin/bash
# Install all dependencies required to run the kernel-test harness.
# Detects the distribution and uses the appropriate package manager.
# Idempotent — safe to run multiple times.
# Safe to run as root (e.g. Ansible) or as a regular user (uses sudo when needed).
# Usage: make bootstrap
set -euo pipefail
. "$(dirname "$0")/common.sh"

ARCH="${1:?usage: bootstrap.sh <archs> <data_repo>}"
DATA_REPO="${2:?usage: bootstrap.sh <archs> <data_repo>}"

# ── Root vs sudo ──────────────────────────────────────────────────────────────
# Ansible or other root-context runners have EUID=0; regular users need sudo.
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

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
                $SUDO pacman -S --needed --noconfirm gcc-multilib
            fi
            $SUDO pacman -S --needed --noconfirm \
                gcc-multilib aarch64-linux-gnu-gcc riscv64-linux-gnu-gcc make ccache \
                clang lld llvm \
                qemu-system-x86 qemu-system-aarch64 extra/qemu-system-riscv \
                cpio git lzop \
                bc flex bison libelf pahole
            ;;

        apt)
            # Detect Debian codename for backports source entry.
            CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" || echo "")

            # Add ${CODENAME}-backports for dwarves ≥1.25
            # (bookworm ships 1.24; kernels ≥6.0 need ≥1.25 for BTF generation).
            # Pin at priority 100 (below main's 500) so apt NEVER auto-selects
            # backports packages — without the pin, apt may try to upgrade
            # gcc-aarch64-linux-gnu to a backports version whose deps are
            # not satisfiable from main, causing the whole install to fail.
            if [[ -n $CODENAME ]]; then
                BACKPORTS_FILE="/etc/apt/sources.list.d/${CODENAME}-backports.list"
                if [[ ! -f $BACKPORTS_FILE ]]; then
                    info "Adding ${CODENAME}-backports (dwarves ≥1.25)..."
                    echo "deb http://deb.debian.org/debian ${CODENAME}-backports main" | \
                        $SUDO tee "$BACKPORTS_FILE" > /dev/null
                    printf 'Package: *\nPin: release a=%s-backports\nPin-Priority: 100\n' \
                        "$CODENAME" | \
                        $SUDO tee "/etc/apt/preferences.d/${CODENAME}-backports-pin" > /dev/null
                fi
            fi

            $SUDO apt-get update -qq
            # Base packages from main; qemu-system-misc provides qemu-system-riscv64
            $SUDO apt-get install -y \
                gcc gcc-multilib make ccache \
                clang lld llvm \
                qemu-system-x86 qemu-system-arm qemu-system-misc \
                cpio git lzop libssl-dev \
                bc flex bison libelf-dev

            # Cross-compilers in a separate step so a broken pre-existing package
            # state does not abort the rest of bootstrap.
            $SUDO apt-get install -y gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu || {
                warn "Cross-compiler install failed — arm64/riscv kernel builds will not work"
                warn "Fix with: sudo apt-get install -f && sudo apt-get install gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu"
            }

            # Install dwarves and qemu-system-misc from backports via explicit -t.
            # dwarves: bookworm ships 1.24; ≥1.25 needed for BTF on kernels ≥6.0.
            # qemu-system-misc: bookworm QEMU 7.2 has riscv64 ISA gaps — the
            # B-extension (zba/zbb/zbs) used by Toybox 0.8.14 is not emulated,
            # causing SIGILL in init. Backports ships QEMU ≥8.x which emulates
            # these instructions correctly.
            if [[ -n ${CODENAME:-} ]] && [[ -f /etc/apt/sources.list.d/${CODENAME}-backports.list ]]; then
                $SUDO apt-get install -y -t "${CODENAME}-backports" dwarves qemu-system-misc || \
                    warn "Could not upgrade from backports — BTF and/or riscv64 QEMU may not work correctly"
            else
                $SUDO apt-get install -y dwarves
            fi
            ;;

        dnf)
            $SUDO dnf install -y \
                gcc gcc-multilib gcc-aarch64-linux-gnu make ccache \
                clang lld llvm \
                qemu-system-x86 qemu-system-aarch64 \
                cpio git lzop \
                bc flex bison elfutils-libelf-devel dwarves
            ;;

        zypper)
            $SUDO zypper install -y \
                gcc gcc-multilib cross-aarch64-linux-gnu-gcc make ccache \
                clang lld llvm \
                qemu-x86 qemu-arm \
                cpio git lzop \
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

TOYBOX_VERSION=${TOYBOX_VERSION:-0.8.14}
CACHE_DIR=${CACHE_DIR:-cache}

download_toybox() {
    mkdir -p "$CACHE_DIR"
    for ta in ${ARCH}; do
        lib/download-toybox.sh "${ta}"
    done
}

info "Downloading Toybox ${TOYBOX_VERSION} static binaries..."
download_toybox

# ── Namespace test binaries ───────────────────────────────────────────────────
# Build the ns-* static C binaries for all 4 arches.
# These are injected into the initramfs at usr/bin/ns-* so the VM tests can
# exercise namespace regression paths that Toybox shell cannot cover directly.

NS_DIR="$(cd "$(dirname "$0")/../tests/ns" && pwd)"
if [[ -d $NS_DIR ]]; then
    info "Building namespace test binaries (tests/ns/)..."
    if make -C "$NS_DIR" all; then
        info "Namespace test binaries built OK"
    else
        warn "Namespace test binaries build failed — ns-* tests will skip in the VM"
    fi
else
    warn "tests/ns/ not found — namespace test binaries will not be available"
fi

# ── perf-event binary ─────────────────────────────────────────────────────────
# Build the perf-event static C binary for all 4 arches.
# Injected into the initramfs at usr/bin/perf-event for 400_perf-events.sh.

PERF_DIR="$(cd "$(dirname "$0")/../tests/programs/perf-event" && pwd)"
if [[ -d $PERF_DIR ]]; then
    info "Building perf-event binary (tests/programs/perf-event/)..."
    if make -C "$PERF_DIR" all; then
        info "perf-event binary built OK"
    else
        warn "perf-event binary build failed — 400_perf-events will skip in the VM"
    fi
else
    warn "tests/programs/perf-event/ not found — 400_perf-events will skip in the VM"
fi

# ── KVM access ────────────────────────────────────────────────────────────────

setup_kvm() {
    if [[ ! -e /dev/kvm ]]; then
        warn "/dev/kvm not found — hardware virtualisation may be disabled in BIOS/UEFI"
        warn "Tests will run in TCG (software) mode — expect 5–10× slower boot"
        return
    fi

    # Running as root: /dev/kvm is accessible directly; no group setup needed.
    if [[ $EUID -eq 0 ]]; then
        info "Running as root — /dev/kvm accessible, skipping kvm group setup"
        return
    fi

    if groups | grep -qw kvm; then
        info "User '$USER' is already in the kvm group"
    else
        info "Adding '$USER' to the kvm group..."
        $SUDO usermod -aG kvm "$USER"
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
    warn "On Arch:   sudo pacman -S gcc-multilib lib32-glibc"
    warn "On Debian: sudo apt-get install gcc-multilib"
    warn "Continuing with x86_64 only: make ARCHS=x86_64"
fi

# ── aarch64-linux-gnu-gcc sanity check (arm64 kernel builds) ─────────────────

if command -v aarch64-linux-gnu-gcc &>/dev/null; then
    info "aarch64-linux-gnu-gcc: OK (arm64 cross-compilation supported)"
else
    warn "aarch64-linux-gnu-gcc not found — arm64 kernel builds will not work"
    warn "arm64 is in the default ARCHS — exclude it with ARCHS=\"x86_64 i386 riscv\" or install aarch64-linux-gnu-gcc"
fi

# ── riscv64-linux-gnu-gcc sanity check (riscv kernel builds) ─────────────────

if command -v riscv64-linux-gnu-gcc &>/dev/null; then
    info "riscv64-linux-gnu-gcc: OK (riscv cross-compilation supported)"
else
    warn "riscv64-linux-gnu-gcc not found — riscv kernel builds will not work"
    warn "riscv is in the default ARCHS — exclude it with ARCHS=\"x86_64 i386 arm64\" or install riscv64-linux-gnu-gcc"
fi

# ── clang/LLVM sanity check (make verify-patch COMPILER=clang|both) ──────────
# clang=compiler, ld.lld=linker (lld pkg), llvm-ar/llvm-nm/...=tools (llvm pkg).
# All three packages are needed; clang does not pull in llvm-ar on any distro.

if command -v clang &>/dev/null; then
    info "clang: OK ($(clang --version 2>&1 | head -1))"
else
    warn "clang not found — make verify-patch COMPILER=clang will not work"
    warn "On Arch:   sudo pacman -S clang lld llvm"
    warn "On Debian: sudo apt-get install clang lld llvm"
fi

if command -v llvm-ar &>/dev/null; then
    info "llvm-ar: OK (kernel LLVM=1 toolchain complete)"
else
    warn "llvm-ar not found — kernel LLVM=1 builds will fail even if clang is present"
    warn "On Arch:   sudo pacman -S llvm"
    warn "On Debian: sudo apt-get install llvm"
fi

# ── pahole version check (BTF/debug info for kernels ≥6.0) ───────────────────

check_pahole_version() {
    if ! command -v pahole &>/dev/null; then
        warn "pahole not found — BTF/debug info will be unavailable for recent kernels"
        return
    fi
    local ver major minor
    ver=$(pahole --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
    major=${ver%%.*}
    minor=${ver##*.}
    if [[ $major -lt 1 ]] || { [[ $major -eq 1 ]] && [[ $minor -lt 25 ]]; }; then
        warn "pahole ${ver} detected — ≥1.25 required for BTF in kernels ≥6.0"
        warn "On Debian: sudo apt-get install -t bookworm-backports dwarves"
    else
        info "pahole ${ver}: OK (BTF generation supported)"
    fi
}

check_pahole_version

# ── Verify all required tools are present ────────────────────────────────────
# Core tools always checked; arch-specific QEMU binaries and cross-compilers
# gated on the ARCHS passed to bootstrap so a partial-arch setup is valid.

REQUIRED=(gcc make ccache cpio git bc flex bison lzop clang llvm-ar)
for a in ${ARCH}; do
    case "$a" in
        x86_64) REQUIRED+=(qemu-system-x86_64) ;;
        i386)   REQUIRED+=(qemu-system-i386) ;;
        arm64)  REQUIRED+=(qemu-system-aarch64 aarch64-linux-gnu-gcc) ;;
        riscv)  REQUIRED+=(qemu-system-riscv64 riscv64-linux-gnu-gcc) ;;
    esac
done

missing=0
info "Checking required tools (ARCHS: ${ARCH}):"
for cmd in "${REQUIRED[@]}"; do
    path=$(command -v "$cmd" 2>/dev/null || true)
    if [[ -n $path ]]; then
        printf '  %-32s %s\n' "$cmd" "$path"
    else
        printf '  %-32s MISSING\n' "$cmd"
        missing=$((missing + 1))
    fi
done

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

# ── Data repository ───────────────────────────────────────────────────────────

setup_data_repo() {
    local repo="$1"
    if [[ ! -d "$repo" ]]; then
        info "Cloning kernel-test-data → $repo"
        git clone https://github.com/bb-claw/kernel-test-data.git "$repo"
    else
        info "Updating kernel-test-data ($repo)"
        git -C "$repo" pull --rebase
    fi
}

setup_data_repo "$DATA_REPO"

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
