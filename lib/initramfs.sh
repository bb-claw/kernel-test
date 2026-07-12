#!/bin/bash
# Build a minimal Toybox cpio initramfs for one architecture.
# Usage: initramfs.sh <arch>
# Output: build/initramfs-<arch>.cpio.gz
set -euo pipefail
. "$(dirname "$0")/common.sh"

ARCH=${1:?usage: initramfs.sh <arch>}

require_env BUILD_DIR CACHE_DIR

STAGE="$BUILD_DIR/initramfs-$ARCH"
OUTPUT="$BUILD_DIR/initramfs-$ARCH.cpio.gz"

# ── Locate Toybox binary for this arch ───────────────────────────────────────
# Map kernel arch name → Toybox binary name (matches landley.net download names).

case "$ARCH" in
    x86_64) TOYBOX_ARCH=x86_64  ;;
    i386)   TOYBOX_ARCH=i686    ;;
    arm64)  TOYBOX_ARCH=aarch64 ;;
    *)      die "Unsupported arch for initramfs: $ARCH (no Toybox binary mapping)" ;;
esac

TOYBOX="$CACHE_DIR/toybox-$TOYBOX_ARCH"
[[ -f $TOYBOX && -x $TOYBOX ]] || \
    die "Toybox binary not found: $TOYBOX — run: make bootstrap"

# ── Build staging tree ────────────────────────────────────────────────────────

info "Building initramfs for $ARCH in $STAGE (toybox-$TOYBOX_ARCH)"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,dev,proc,sys,tmp,tests}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Install Toybox ────────────────────────────────────────────────────────────

cp "$TOYBOX" "$STAGE/bin/toybox"
chmod +x "$STAGE/bin/toybox"

# Symlinks for all Toybox applets.
# --list may emit space-separated or newline-separated output depending on version;
# tr normalises to one-per-line; grep strips blanks and the "toybox" entry so the
# loop body is a plain ln — avoids [[ ]] && continue triggering set -e on mismatch.
"$STAGE/bin/toybox" 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | grep -vxF 'toybox' \
    | while read -r applet; do
        ln -sf toybox "$STAGE/bin/$applet"
    done

# ── Write /init ───────────────────────────────────────────────────────────────

cat > "$STAGE/init" << 'EOF'
#!/bin/sh

mount -t proc     none /proc      2>/dev/null || true
mount -t sysfs    none /sys       2>/dev/null || true
mount -t devtmpfs none /dev       2>/dev/null || {
    # devtmpfs not compiled in (e.g. tinyconfig) — create minimum devices
    mknod -m 600 /dev/console c 5 1 2>/dev/null || true
    mknod -m 666 /dev/null    c 1 3 2>/dev/null || true
}

echo "BOOT_OK: kernel reached init"

for t in $(ls /tests/*.sh 2>/dev/null | sort); do
    [ -f "$t" ] || continue
    name=$(basename "$t" .sh)
    echo "> TEST RUN: $name"
    if sh "$t"; then
        echo "< TEST PASS: $name"
    else
        echo "< TEST FAIL: $name"
    fi
done

echo "TEST_DONE"
# Brief pause so the emulated UART drains to the serial file before QEMU exits.
sleep 1
reboot -f
EOF
chmod +x "$STAGE/init"

# ── Copy tests ────────────────────────────────────────────────────────────────

if [[ -f "$SCRIPT_DIR/tests/001_smoke.sh" ]]; then
    cp "$SCRIPT_DIR/tests/001_smoke.sh" "$STAGE/tests/"
    chmod +x "$STAGE/tests/001_smoke.sh"
fi

if [[ -d "$SCRIPT_DIR/tests/custom" ]]; then
    for f in "$SCRIPT_DIR/tests/custom/"*.sh; do
        [[ -f $f ]] || continue
        cp "$f" "$STAGE/tests/"
        chmod +x "$STAGE/tests/$(basename "$f")"
    done
fi

# ── Pack cpio + gzip ──────────────────────────────────────────────────────────

info "Packing initramfs → $OUTPUT"
(cd "$STAGE" && find . | cpio -oH newc 2>/dev/null | gzip -9) > "$OUTPUT"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
info "Initramfs ready: $OUTPUT ($SIZE)"
