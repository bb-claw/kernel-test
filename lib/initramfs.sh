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

TOYBOX_ARCH=$(arch_toybox_name "$ARCH")

TOYBOX="$CACHE_DIR/toybox-$TOYBOX_ARCH"
[[ -f $TOYBOX && -x $TOYBOX ]] || \
    die "Toybox binary not found: $TOYBOX — run: make bootstrap"

# ── Build staging tree ────────────────────────────────────────────────────────

info "Building initramfs for $ARCH in $STAGE (toybox-$TOYBOX_ARCH)"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,usr/bin,dev,proc,sys,tmp,tests}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Install Toybox ────────────────────────────────────────────────────────────

cp "$TOYBOX" "$STAGE/bin/toybox"
chmod +x "$STAGE/bin/toybox"

# Symlinks for all Toybox applets.
# Cross-arch binaries (arm64, riscv) cannot execute on the x86_64 build host;
# fall back to the native x86_64 binary for the applet list — the set is
# identical across arches for the same Toybox version.
# --list may emit space-separated or newline-separated output depending on version;
# tr normalises to one-per-line; grep strips blanks and the "toybox" entry so the
# loop body is a plain ln — avoids [[ ]] && continue triggering set -e on mismatch.
TOYBOX_LIST_BIN="$STAGE/bin/toybox"
if ! "$TOYBOX_LIST_BIN" &>/dev/null; then
    TOYBOX_LIST_BIN="$CACHE_DIR/toybox-x86_64"
    [[ -x $TOYBOX_LIST_BIN ]] || \
        die "Toybox applet list unavailable: $ARCH binary is not natively executable and toybox-x86_64 not found in $CACHE_DIR"
fi
"$TOYBOX_LIST_BIN" 2>/dev/null \
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
    if /bin/sh "$t"; then
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

# ── Copy ns-* test binaries ───────────────────────────────────────────────────

NS_BIN_DIR="$SCRIPT_DIR/tests/ns/bin/$ARCH"
if [[ -d "$NS_BIN_DIR" ]]; then
    ns_count=0
    for bin in "$NS_BIN_DIR"/ns-*; do
        [[ -f $bin && -x $bin ]] || continue
        cp "$bin" "$STAGE/usr/bin/"
        ns_count=$((ns_count + 1))
    done
    [[ $ns_count -gt 0 ]] && info "Namespace test binaries installed: $ns_count binaries → $STAGE/usr/bin/"
else
    warn "Namespace test binaries not found ($NS_BIN_DIR) — run: make bootstrap  (ns-* tests will skip)"
fi

# ── Copy perf-event binary ────────────────────────────────────────────────────

PERF_BIN="$SCRIPT_DIR/tests/programs/perf-event/bin/$ARCH/perf-event"
if [[ -x "$PERF_BIN" ]]; then
    cp "$PERF_BIN" "$STAGE/usr/bin/"
    info "perf-event binary installed → $STAGE/usr/bin/"
else
    warn "perf-event binary not found ($PERF_BIN) — run: make bootstrap  (400_perf-events will skip)"
fi

# ── Copy arena-test binary ────────────────────────────────────────────────────

ARENA_BIN="$SCRIPT_DIR/tests/programs/arena-test/bin/$ARCH/arena-test"
if [[ -x "$ARENA_BIN" ]]; then
    cp "$ARENA_BIN" "$STAGE/usr/bin/"
    info "arena-test binary installed → $STAGE/usr/bin/"
else
    warn "arena-test binary not found ($ARENA_BIN) — run: make bootstrap  (410_arena-memory will skip)"
fi

# ── Pack cpio + gzip ──────────────────────────────────────────────────────────

info "Packing initramfs → $OUTPUT"
(cd "$STAGE" && find . | cpio -oH newc 2>/dev/null | gzip -9) > "$OUTPUT"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
info "Initramfs ready: $OUTPUT ($SIZE)"
