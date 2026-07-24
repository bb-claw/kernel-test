#!/bin/bash
# Download a Toybox static binary for one architecture to the cache directory.
# Usage: download-toybox.sh <arch>   (arch = x86_64 | i386 | arm64 | riscv)
# Idempotent — skips download if the binary is already cached.
set -euo pipefail
. "$(dirname "$0")/common.sh"

ARCH="${1:?usage: download-toybox.sh <arch>}"
TOYBOX_VERSION=${TOYBOX_VERSION:-0.8.14}
CACHE_DIR=${CACHE_DIR:-cache}
TOYBOX_BASE_URL="https://www.landley.net/toybox/downloads/binaries/${TOYBOX_VERSION}"

# ── Locate Toybox binary for this arch ───────────────────────────────────────
# Map kernel arch name → Toybox binary name (matches landley.net download names).

case "$ARCH" in
    x86_64) TOYBOX_ARCH=x86_64  ;;
    i386)   TOYBOX_ARCH=i686    ;;
    arm64)  TOYBOX_ARCH=aarch64 ;;
    riscv)  TOYBOX_ARCH=riscv64 ;;
    *)      die "Unsupported arch for initramfs: $ARCH (no Toybox binary mapping)" ;;
esac


# ── Toybox: download static binaries for each arch ───────────────────────────

download_toybox() {
    mkdir -p "$CACHE_DIR"
    local dest="$CACHE_DIR/toybox-${TOYBOX_ARCH}"
    if [[ -f $dest && -x $dest ]]; then
        info "toybox-${TOYBOX_ARCH} already cached: $dest"
        return
    fi
    local url="${TOYBOX_BASE_URL}/toybox-${TOYBOX_ARCH}"
    info "Downloading toybox-${TOYBOX_ARCH} ${TOYBOX_VERSION}..."
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
}

check_toybox() {
    local ok=1
    local dest="$CACHE_DIR/toybox-${TOYBOX_ARCH}"
    if [[ -f $dest && -x $dest ]]; then
        info "toybox-${TOYBOX_ARCH}: OK  ($dest)"
    else
        warn "toybox-${TOYBOX_ARCH}: MISSING — run: make bootstrap"
        ok=0
    fi
    [[ $ok -eq 1 ]]
}

info "Downloading Toybox ${TOYBOX_VERSION} static binaries..."
download_toybox
check_toybox || warn "Toybox binary missing — initramfs builds will fail"


