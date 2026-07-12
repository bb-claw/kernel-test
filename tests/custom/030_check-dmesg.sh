#!/bin/sh
# Scan the kernel ring buffer for serious errors and collect statistics.
# WARNINGs are reported but do not cause test failure — only BUG/Oops do.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }
info() { printf 'info: %s\n' "$*"; }

if ! command -v dmesg >/dev/null 2>&1; then
    skip "dmesg not available"
    exit 0
fi

KLOG=$(dmesg 2>/dev/null) || { skip "dmesg not readable"; exit 0; }

# BUG: — kernel assertion failure, always a hard failure
if printf '%s\n' "$KLOG" | grep -q "BUG:"; then
    first=$(printf '%s\n' "$KLOG" | grep "BUG:" | head -1)
    count=$(printf '%s\n' "$KLOG" | grep -c "BUG:" || echo 0)
    fail "kernel BUG (${count}x): $first"
else
    ok "no kernel BUG"
fi

# Oops: — kernel fault
if printf '%s\n' "$KLOG" | grep -q "Oops:"; then
    first=$(printf '%s\n' "$KLOG" | grep "Oops:" | head -1)
    count=$(printf '%s\n' "$KLOG" | grep -c "Oops:" || echo 0)
    fail "kernel Oops (${count}x): $first"
else
    ok "no kernel Oops"
fi

# WARNING: — report count, do not fail
warn_count=$(printf '%s\n' "$KLOG" | grep -c "WARNING:" || echo 0)
if [ "$warn_count" -gt 0 ]; then
    info "${warn_count} WARNING(s) in dmesg"
    printf '%s\n' "$KLOG" | grep "WARNING:" | head -5 | while read -r line; do
        info "  $line"
    done
else
    ok "no kernel WARNINGs"
fi

# Call trace — present after BUG/Oops/WARN, informational
if printf '%s\n' "$KLOG" | grep -q "Call Trace:"; then
    ct_count=$(printf '%s\n' "$KLOG" | grep -c "Call Trace:" || echo 0)
    info "${ct_count} Call Trace(s) in dmesg"
fi

# Kernel version line — sanity check that we actually read the right log
if printf '%s\n' "$KLOG" | grep -q "Linux version"; then
    kver=$(printf '%s\n' "$KLOG" | grep "Linux version" | head -1 | \
        sed 's/.*Linux version //' | cut -d' ' -f1)
    ok "kernel version: $kver"
else
    fail "kernel version line not found in dmesg"
fi

[ $fails -eq 0 ] || exit 1
