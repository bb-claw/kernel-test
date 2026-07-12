#!/bin/sh
# Read and write /proc/sys entries — exercises the sysctl interface and the
# kernel parameter subsystem.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -d /proc/sys ]; then
    skip "/proc/sys not present (CONFIG_PROC_SYSCTL may be off)"
    exit 0
fi

# kernel.pid_max — must be > 0
if [ -r /proc/sys/kernel/pid_max ]; then
    val=$(cat /proc/sys/kernel/pid_max)
    if [ "${val:-0}" -gt 0 ]; then
        ok "kernel.pid_max = $val"
    else
        fail "kernel.pid_max is zero or missing"
    fi
else
    skip "kernel.pid_max not readable"
fi

# kernel.hostname — read
if [ -r /proc/sys/kernel/hostname ]; then
    val=$(cat /proc/sys/kernel/hostname)
    if [ -n "$val" ]; then
        ok "kernel.hostname = $val"
    else
        fail "kernel.hostname is empty"
    fi
else
    skip "kernel.hostname not readable"
fi

# kernel.hostname — write/read/restore
if [ -w /proc/sys/kernel/hostname ]; then
    old=$(cat /proc/sys/kernel/hostname)
    printf 'kernel-test\n' > /proc/sys/kernel/hostname
    new=$(cat /proc/sys/kernel/hostname)
    printf '%s\n' "$old" > /proc/sys/kernel/hostname
    if [ "$new" = "kernel-test" ]; then
        ok "kernel.hostname write/read/restore"
    else
        fail "kernel.hostname write/read mismatch (got: '$new')"
    fi
else
    skip "kernel.hostname not writable"
fi

# kernel.panic — read (must be a number)
if [ -r /proc/sys/kernel/panic ]; then
    val=$(cat /proc/sys/kernel/panic)
    if printf '%s' "$val" | grep -qE '^-?[0-9]+$'; then
        ok "kernel.panic = $val"
    else
        fail "kernel.panic not numeric (got: '$val')"
    fi
else
    skip "kernel.panic not readable"
fi

# vm.swappiness — read (must be 0–200)
if [ -r /proc/sys/vm/swappiness ]; then
    val=$(cat /proc/sys/vm/swappiness)
    if [ "${val:-999}" -le 200 ]; then
        ok "vm.swappiness = $val"
    else
        fail "vm.swappiness out of range (got: '$val')"
    fi
else
    skip "vm.swappiness not readable"
fi

[ $fails -eq 0 ] || exit 1
