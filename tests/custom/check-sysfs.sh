#!/bin/sh
# Verify /sys filesystem structure.
# Skipped when CONFIG_SYSFS is not enabled.

_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -d /sys ] || [ ! -d /sys/kernel ]; then
    skip "sysfs not mounted — skipping check-sysfs"
    exit 0
fi

# Core sysfs directories
for d in /sys/kernel /sys/class /sys/bus /sys/devices; do
    [ -d "$d" ] \
        && ok "$d exists" || fail "$d missing"
done

# /sys/kernel/osrelease — kernel version string
if [ -r /sys/kernel/osrelease ]; then
    ver=$(cat /sys/kernel/osrelease)
    # Must start with a digit and contain a dot
    case "$ver" in
        [0-9]*.*) ok "/sys/kernel/osrelease=$ver" ;;
        *)        fail "/sys/kernel/osrelease malformed: $ver" ;;
    esac
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

[ $_fails -eq 0 ] || exit 1
