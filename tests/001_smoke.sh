#!/bin/sh
# Smoke test — the bare minimum that must work for any config that reaches init.
# Failure here means the kernel or initramfs is fundamentally broken.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# Shell is functional
val=$(( 1 + 1 ))
if [ "$val" = "2" ]; then
    ok "shell arithmetic"
else
    fail "shell arithmetic broken"
fi

# /dev/null is usable (created by /init if devtmpfs unavailable)
if [ -e /dev/null ]; then
    printf '' > /dev/null \
        && ok "/dev/null writable" || fail "/dev/null not writable"
else
    skip "/dev/null not present"
fi

# /proc/version — present only when CONFIG_PROC_FS is enabled
if [ -r /proc/version ]; then
    grep -q "Linux" /proc/version \
        && ok "/proc/version contains Linux" \
        || fail "/proc/version does not contain Linux"
else
    skip "/proc/version not readable (CONFIG_PROC_FS may be off)"
fi

# /sys present — CONFIG_SYSFS
if [ -d /sys/kernel ]; then
    ok "/sys/kernel exists"
else
    skip "/sys/kernel not present (CONFIG_SYSFS may be off)"
fi

[ $fails -eq 0 ] || exit 1
