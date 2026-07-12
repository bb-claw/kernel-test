#!/bin/bash
# Boot one (config, arch) kernel in QEMU/KVM, capture serial output, detect
# pass/fail, and write build/<config>-<arch>/vm.status.
# Usage: vm.sh <config> <arch>
set -euo pipefail
. "$(dirname "$0")/common.sh"

CONFIG=${1:?usage: vm.sh <config> <arch>}
ARCH=${2:?usage: vm.sh <config> <arch>}

require_env BUILD_DIR TIMEOUT

OUT_DIR="$BUILD_DIR/$CONFIG-$ARCH"
INITRAMFS="$BUILD_DIR/initramfs-$ARCH.cpio.gz"
DMESG_FILE="$OUT_DIR/dmesg.txt"
QEMU_LOG="$OUT_DIR/qemu.log"
STATUS_FILE="$OUT_DIR/vm.status"

# ── Architecture-specific settings ───────────────────────────────────────────

case "$ARCH" in
    x86_64)
        QEMU=qemu-system-x86_64
        QEMU_MACHINE=q35
        BZIMAGE="$OUT_DIR/arch/x86/boot/bzImage"
        ;;
    i386)
        QEMU=qemu-system-i386
        QEMU_MACHINE=pc
        BZIMAGE="$OUT_DIR/arch/x86/boot/bzImage"
        ;;
    *)
        die "Unsupported arch: $ARCH"
        ;;
esac

# ── Pre-flight checks ─────────────────────────────────────────────────────────

command -v "$QEMU" &>/dev/null  || die "$QEMU not found in PATH"
[[ -f $BZIMAGE ]]               || die "bzImage not found: $BZIMAGE (did 'make build' succeed?)"
[[ -f $INITRAMFS ]]             || die "initramfs not found: $INITRAMFS (did 'make initramfs' succeed?)"

mkdir -p "$OUT_DIR"
: > "$DMESG_FILE"

# ── KVM availability ──────────────────────────────────────────────────────────

KVM_FLAGS=()
if [[ -r /dev/kvm ]]; then
    KVM_FLAGS=(-enable-kvm)
else
    warn "KVM not available — running in TCG mode (expect slow boot)"
fi

# ── Boot the kernel ───────────────────────────────────────────────────────────

info "Booting $CONFIG / $ARCH (timeout: ${TIMEOUT}s)"

VM_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VM_START_EPOCH=$(date -u +%s)

QEMU_EXIT=0
timeout "$TIMEOUT" "$QEMU" \
    "${KVM_FLAGS[@]}" \
    -M "$QEMU_MACHINE" \
    -m 512M \
    -display none \
    -no-reboot \
    -kernel "$BZIMAGE" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0 panic=5 quiet" \
    -serial "file:$DMESG_FILE" \
    > /dev/null 2> "$QEMU_LOG" \
    || QEMU_EXIT=$?

# ── Parse serial output ───────────────────────────────────────────────────────

BOOT_OK=0
PANIC=0
OOPS=0
TEST_DONE=0
PASS_COUNT=0
FAIL_COUNT=0
TESTS_TOTAL=0
KUNIT_PASS=0
KUNIT_FAIL=0

if [[ -s $DMESG_FILE ]]; then
    grep -q  "BOOT_OK:"   "$DMESG_FILE" 2>/dev/null && BOOT_OK=1   || true
    grep -qi "Kernel panic" "$DMESG_FILE" 2>/dev/null && PANIC=1   || true
    grep -q  "Oops:"      "$DMESG_FILE" 2>/dev/null && OOPS=1      || true
    grep -qF "TEST_DONE"  "$DMESG_FILE" 2>/dev/null && TEST_DONE=1 || true

    # Count test-level results from the init wrapper markers.
    # grep -c exits 1 on zero matches — use "|| true" not "|| echo 0" (avoids "0\n0").
    PASS_COUNT=$(grep -c "^< TEST PASS:" "$DMESG_FILE" 2>/dev/null || true)
    FAIL_COUNT=$(grep -c "^< TEST FAIL:" "$DMESG_FILE" 2>/dev/null || true)
    PASS_COUNT=${PASS_COUNT:-0}
    FAIL_COUNT=${FAIL_COUNT:-0}
    TESTS_TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
    # Space-separated list of failed test names for reporting
    FAILED_TESTS=$(grep "^< TEST FAIL:" "$DMESG_FILE" 2>/dev/null \
        | sed 's/^< TEST FAIL: //' | tr '\n' ' ' | sed 's/ $//' || true)
    FAILED_TESTS=${FAILED_TESTS:-}

    # Count KUnit KTAP results.
    # Individual test lines are indented (4+ spaces after the timestamp);
    # top-level suite summary lines have no indent — excluded to avoid double-counting.
    # Only attempt parsing when KTAP output is present.
    if grep -qE 'KTAP version|# Subtest:' "$DMESG_FILE" 2>/dev/null; then
        KUNIT_PASS=$(grep -cE '^\[[ 0-9.]+\] {4,}ok [0-9]+'     "$DMESG_FILE" 2>/dev/null || true)
        KUNIT_FAIL=$(grep -cE '^\[[ 0-9.]+\] {4,}not ok [0-9]+' "$DMESG_FILE" 2>/dev/null || true)
        KUNIT_PASS=${KUNIT_PASS:-0}
        KUNIT_FAIL=${KUNIT_FAIL:-0}
    fi
fi

# ── Determine overall result ──────────────────────────────────────────────────

if [[ $BOOT_OK -eq 1 && $PANIC -eq 0 && $OOPS -eq 0 ]]; then
    if [[ $TEST_DONE -eq 0 ]]; then
        BOOT_STATUS=FAIL
        FAIL_REASON="Init started but TEST_DONE not reached — VM may have crashed mid-test"
    else
        BOOT_STATUS=PASS
        FAIL_REASON=''
    fi
else
    BOOT_STATUS=FAIL
    if   [[ $PANIC -eq 1 ]]; then
        FAIL_REASON=$(grep -m1 "Kernel panic" "$DMESG_FILE" 2>/dev/null || echo "Kernel panic")
    elif [[ $OOPS -eq 1 ]]; then
        FAIL_REASON=$(grep -m1 "Oops:"        "$DMESG_FILE" 2>/dev/null || echo "Oops")
    elif [[ $QEMU_EXIT -eq 124 ]]; then
        FAIL_REASON="Timeout after ${TIMEOUT}s — kernel did not reach init"
    else
        FAIL_REASON="Did not reach init (QEMU exit ${QEMU_EXIT})"
    fi
fi

# ── Write status file ─────────────────────────────────────────────────────────

{
    printf 'BOOT=%s\n'        "$BOOT_STATUS"
    printf 'TEST_DONE=%d\n'   "$TEST_DONE"
    printf 'TESTS_TOTAL=%d\n' "$TESTS_TOTAL"
    printf 'TESTS_PASS=%d\n'  "$PASS_COUNT"
    printf 'TESTS_FAIL=%d\n'  "$FAIL_COUNT"
    printf 'KUNIT_PASS=%d\n'  "$KUNIT_PASS"
    printf 'KUNIT_FAIL=%d\n'  "$KUNIT_FAIL"
    printf 'START_TIME=%s\n'  "$VM_START_TIME"
    printf 'DURATION=%d\n'    "$(( $(date -u +%s) - VM_START_EPOCH ))"
    [[ -n $FAIL_REASON    ]] && printf 'FAIL_REASON=%s\n'    "$FAIL_REASON"
    [[ -n $FAILED_TESTS   ]] && printf 'FAILED_TESTS=%s\n'   "$FAILED_TESTS"
} > "$STATUS_FILE"

# ── Report result ─────────────────────────────────────────────────────────────

KUNIT_TOTAL=$(( KUNIT_PASS + KUNIT_FAIL ))
TOTAL_FAIL=$(( FAIL_COUNT + KUNIT_FAIL ))

if [[ $BOOT_STATUS == PASS ]]; then
    if [[ $TOTAL_FAIL -eq 0 ]]; then
        if [[ $KUNIT_TOTAL -gt 0 ]]; then
            info "PASS  $CONFIG / $ARCH — boot OK, tests ${PASS_COUNT}/${TESTS_TOTAL}, kunit ${KUNIT_PASS}/${KUNIT_TOTAL}"
        else
            info "PASS  $CONFIG / $ARCH — boot OK, tests ${PASS_COUNT}/${TESTS_TOTAL}"
        fi
    else
        if [[ $FAIL_COUNT -gt 0 && $KUNIT_FAIL -gt 0 ]]; then
            warn "PARTIAL  $CONFIG / $ARCH — booted, but ${FAIL_COUNT} test(s) and ${KUNIT_FAIL} kunit test(s) failed"
        elif [[ $FAIL_COUNT -gt 0 ]]; then
            warn "PARTIAL  $CONFIG / $ARCH — booted, but ${FAIL_COUNT} test(s) failed"
        else
            warn "PARTIAL  $CONFIG / $ARCH — booted, but ${KUNIT_FAIL} kunit test(s) failed"
        fi
        for _ft in $FAILED_TESTS; do
            warn "  FAIL: $_ft"
        done
        exit 1
    fi
else
    warn "FAIL  $CONFIG / $ARCH — ${FAIL_REASON}"
    exit 1
fi
