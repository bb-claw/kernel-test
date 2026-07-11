#!/bin/bash
# Build a minimal BusyBox cpio initramfs for one architecture.
# Usage: initramfs.sh <arch>
# Output: build/initramfs-<arch>.cpio.gz
set -euo pipefail
. "$(dirname "$0")/common.sh"

ARCH=${1:?usage: initramfs.sh <arch>}

require_env BUILD_DIR

STAGE="$BUILD_DIR/initramfs-$ARCH"
OUTPUT="$BUILD_DIR/initramfs-$ARCH.cpio.gz"

# ── Locate static BusyBox ─────────────────────────────────────────────────────

BUSYBOX=$(command -v busybox 2>/dev/null || true)
[[ -n $BUSYBOX && -x $BUSYBOX ]] || die "busybox not found in PATH"

if file "$BUSYBOX" 2>/dev/null | grep -q 'dynamically linked'; then
    warn "busybox at $BUSYBOX is dynamically linked — shared libs will be missing in the VM"
fi

# ── Build staging tree ────────────────────────────────────────────────────────

info "Building initramfs for $ARCH in $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,dev,proc,sys,tmp,tests}

# BusyBox binary
cp "$BUSYBOX" "$STAGE/bin/busybox"
chmod +x "$STAGE/bin/busybox"

# Symlinks for all BusyBox applets (skip 'busybox' itself — would overwrite the binary)
"$BUSYBOX" --list | while read -r applet; do
    [[ $applet == busybox ]] && continue
    ln -sf busybox "$STAGE/bin/$applet"
done

# ── /init script ─────────────────────────────────────────────────────────────

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

for t in /tests/*.sh; do
    [ -f "$t" ] || continue
    if sh "$t"; then
        echo "PASS: $t"
    else
        echo "FAIL: $t"
    fi
done

echo "TEST_DONE"
poweroff -f
EOF
chmod +x "$STAGE/init"

# ── Copy tests ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$SCRIPT_DIR/tests/smoke.sh" ]]; then
    cp "$SCRIPT_DIR/tests/smoke.sh" "$STAGE/tests/"
    chmod +x "$STAGE/tests/smoke.sh"
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
