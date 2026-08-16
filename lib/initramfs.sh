#!/bin/bash
# Build a minimal Toybox cpio initramfs for one (config, arch) pair.
# Usage: initramfs.sh <config> <arch>
# Output: build/initramfs-<config>-<arch>.cpio.gz
set -euo pipefail
. "$(dirname "$0")/common.sh"

CONFIG=${1:?usage: initramfs.sh <config> <arch>}
ARCH=${2:?usage: initramfs.sh <config> <arch>}

require_env BUILD_DIR CACHE_DIR

STAGE="$BUILD_DIR/initramfs-$CONFIG-$ARCH"
OUTPUT="$BUILD_DIR/initramfs-$CONFIG-$ARCH.cpio.gz"

# ── Locate Toybox binary for this arch ───────────────────────────────────────

TOYBOX_ARCH=$(arch_toybox_name "$ARCH")

TOYBOX="$CACHE_DIR/toybox-$TOYBOX_ARCH"
[[ -f $TOYBOX && -x $TOYBOX ]] || \
    die "Toybox binary not found: $TOYBOX — run: make bootstrap"

# ── Build staging tree ────────────────────────────────────────────────────────

info "Building initramfs for $CONFIG/$ARCH in $STAGE (toybox-$TOYBOX_ARCH)"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,usr/bin,dev,proc,sys,tmp,tests,etc,root}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Install Toybox ────────────────────────────────────────────────────────────

cp "$TOYBOX" "$STAGE/bin/toybox"
chmod +x "$STAGE/bin/toybox"

# ── Write /etc/passwd and /etc/group ─────────────────────────────────────────
# Toybox sh calls getpwuid(0) in setup_env() to populate HOME/USER/SHELL.
# Without /etc/passwd it falls back to a BSS struct that is corrupted by NOFORK
# TT-union aliasing on SMP hardware (SIGSEGV observed on VisionFive 2 / riscv).
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$STAGE/etc/passwd"
printf 'root:x:0:\n'                      > "$STAGE/etc/group"

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

# Silence console during tests: deferred kernel printk messages (e.g. mmc probe
# errors) are flushed asynchronously and can split "< TEST PASS:" mid-write,
# breaking parse_serial_output's grep anchor. The ring buffer is unaffected.
dmesg -n 1 2>/dev/null || true

# Protocol markers go directly to /dev/console, bypassing Toybox sh's
# block-buffered stdout.  Without this, markers accumulate in the userspace
# buffer and appear out-of-order relative to child test output; TEST_DONE is
# lost entirely because reboot -f skips atexit and never flushes the buffer.
printf 'BOOT_OK: kernel reached init\n' > /dev/console

# Capture clean boot state before test scripts run or add output to the ring buffer.
if [ -x /usr/bin/snapshot ]; then
    /usr/bin/snapshot > /tmp/snapshot.txt 2>/dev/null || true
fi

test_count=0
for t in $(ls /tests/*.sh 2>/dev/null | sort); do
    [ -f "$t" ] && test_count=$((test_count + 1))
done
printf 'kernel-test: starting %s tests\n' "$test_count" > /dev/console

pass_count=0
fail_count=0
for t in $(ls /tests/*.sh 2>/dev/null | sort); do
    [ -f "$t" ] || continue
    name=$(basename "$t" .sh)
    printf '> TEST RUN: %s\n' "$name" > /dev/console
    if /bin/sh "$t"; then
        printf '< TEST PASS: %s\n' "$name" > /dev/console
        pass_count=$((pass_count + 1))
    else
        printf '< TEST FAIL: %s\n' "$name" > /dev/console
        fail_count=$((fail_count + 1))
    fi
done

total=$((pass_count + fail_count))
printf 'kernel-test: %s/%s tests passed\n' "$pass_count" "$total" > /dev/console
printf 'TEST_DONE\n' > /dev/console
# Pause for host to drain capture before board reboots into next U-Boot cycle.
# 5s on real hardware (board.sh) vs QEMU (which exits on reboot anyway).
sleep 5
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

ns_count=0
NS_BIN_DIR="$SCRIPT_DIR/tests/ns/bin/$ARCH"
if [[ -d "$NS_BIN_DIR" ]]; then
    for bin in "$NS_BIN_DIR"/ns-*; do
        [[ -f $bin && -x $bin ]] || continue
        cp "$bin" "$STAGE/usr/bin/"
        ns_count=$((ns_count + 1))
    done
    [[ $ns_count -gt 0 ]] && info "Namespace test binaries installed: $ns_count binaries → $STAGE/usr/bin/"
else
    warn "Namespace test binaries not found ($NS_BIN_DIR) — run: make bootstrap  (ns-* tests will skip)"
fi

# ── Copy single-binary test programs + write capability markers ───────────────
# Each marker is an empty file; tests check it as the first guard before doing
# runtime probes (double-guard pattern: infrastructure ready + kernel feature present).

install_program_binary() {
    local name="$1" bin="$2" marker="$3" test_slot="$4"
    if [[ -x "$bin" ]]; then
        cp "$bin" "$STAGE/usr/bin/"
        info "$name binary installed → $STAGE/usr/bin/"
        touch "$STAGE/tests/$marker"
    else
        warn "$name binary not found ($bin) — run: make bootstrap  ($test_slot will skip)"
    fi
}

install_program_binary "perf-event" \
    "$SCRIPT_DIR/tests/programs/perf-event/bin/$ARCH/perf-event" \
    "perf-enabled" "400_perf-events"

install_program_binary "arena-test" \
    "$SCRIPT_DIR/tests/programs/arena-test/bin/$ARCH/arena-test" \
    "arena-enabled" "410_arena-memory"

# syscall-tests is always injected when present; individual subcommands skip at runtime
# when the required syscall is unavailable. No capability marker needed.
SYSCALL_BIN="$SCRIPT_DIR/tests/programs/syscall-tests/bin/$ARCH/syscall-tests"
if [[ -x "$SYSCALL_BIN" ]]; then
    cp "$SYSCALL_BIN" "$STAGE/usr/bin/"
    info "syscall-tests binary installed → $STAGE/usr/bin/"
else
    warn "syscall-tests binary not found ($SYSCALL_BIN) — run: make bootstrap  (420_–470_ will skip)"
fi

# snapshot is always injected when present; /init runs it before the test loop.
# No capability marker needed (uname/proc/syslog available on all configs).
SNAPSHOT_BIN="$SCRIPT_DIR/tests/programs/snapshot/bin/$ARCH/snapshot"
if [[ -x "$SNAPSHOT_BIN" ]]; then
    cp "$SNAPSHOT_BIN" "$STAGE/usr/bin/"
    info "snapshot binary installed → $STAGE/usr/bin/"
else
    warn "snapshot binary not found ($SNAPSHOT_BIN) — run: make bootstrap  (480_snapshot will skip)"
fi

# ── Write ns-enabled marker ───────────────────────────────────────────────────

# ns-enabled: written when ns-* binaries are installed (make bootstrap was run)
if [[ $ns_count -gt 0 ]]; then
    touch "$STAGE/tests/ns-enabled"
    info "ns-enabled marker written → /tests/ns-enabled"
fi

# watchdog-enabled: written when CONFIG_WATCHDOG=y in the per-(config,arch) .config
CONFIG_FILE="$BUILD_DIR/$CONFIG-$ARCH/.config"
if [[ -f "$CONFIG_FILE" ]] && grep -q '^CONFIG_WATCHDOG=y' "$CONFIG_FILE"; then
    touch "$STAGE/tests/watchdog-enabled"
    info "watchdog-enabled marker written → /tests/watchdog-enabled"
fi

# ── Pack cpio + gzip ──────────────────────────────────────────────────────────

info "Packing initramfs → $OUTPUT"
(cd "$STAGE" && find . | cpio -oH newc 2>/dev/null | gzip -9) > "$OUTPUT"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
info "Initramfs ready: $OUTPUT ($SIZE)"
