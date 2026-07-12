#!/bin/sh
# Verify /sys filesystem structure.
# Skipped when CONFIG_SYSFS is not enabled.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -d /sys ] || [ ! -d /sys/kernel ]; then
    skip "sysfs not mounted — skipping check-sysfs"
    exit 0
fi

# Core sysfs directories
for d in /sys/kernel /sys/class /sys/bus /sys/devices; do
    if [ -d "$d" ]; then
        ok "$d exists"
    else
        fail "$d missing"
    fi
done

# /sys/kernel/osrelease — kernel version string
if [ -r /sys/kernel/osrelease ]; then
    ver=$(cat /sys/kernel/osrelease)
    # Must start with a digit and contain a dot.
    # Avoid case [0-9] — Toybox sh 0.8.9 character class bug (see 050_check-kernel).
    if printf '%s\n' "$ver" | grep -qE '^[0-9]+\.'; then
        ok "/sys/kernel/osrelease=$ver"
    else
        fail "/sys/kernel/osrelease malformed: $ver"
    fi
else
    skip "/sys/kernel/osrelease not readable"
fi

# /sys/kernel/hostname
if [ -r /sys/kernel/hostname ]; then
    ok "/sys/kernel/hostname=$(cat /sys/kernel/hostname)"
else
    skip "/sys/kernel/hostname not readable"
fi

# /sys/class/tty should exist on x86 with default config
if [ -d /sys/class/tty ]; then
    ok "/sys/class/tty exists"
else
    skip "/sys/class/tty not present"
fi

# Power management — expected on x86
if [ -d /sys/power ]; then
    ok "/sys/power exists"
else
    skip "/sys/power not present"
fi

[ $fails -eq 0 ] || exit 1
