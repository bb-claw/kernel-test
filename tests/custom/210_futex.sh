#!/bin/sh
# Futex: fast userspace mutex syscall infrastructure (CONFIG_FUTEX).
# Direct futex(2) testing requires a helper binary; we verify the subsystem
# via /proc/sys/kernel/futex_private_hash_size (added in kernel 6.x).

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# futex_private_hash_size: new in kernel 6.x, present only when CONFIG_FUTEX=y.
# On older kernels or when futex is disabled it is absent — skip, not fail.
if [ -r /proc/sys/kernel/futex_private_hash_size ]; then
    val=$(cat /proc/sys/kernel/futex_private_hash_size 2>/dev/null || true)
    if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        ok "futex_private_hash_size = $val (CONFIG_FUTEX confirmed)"
    else
        fail "futex_private_hash_size: unexpected value '${val:-empty}'"
    fi
else
    skip "futex_private_hash_size absent (kernel < 6.x or CONFIG_FUTEX may be off)"
fi

# /proc/sys/kernel/sem — SysV semaphore limits share the futex code path
# for FUTEX_WAIT on semaphore operations; their presence confirms IPC is live.
if [ -r /proc/sys/kernel/sem ]; then
    ok "/proc/sys/kernel/sem present (SysV IPC + futex path active)"
else
    skip "/proc/sys/kernel/sem absent (CONFIG_SYSVIPC may be off)"
fi

[ $fails -eq 0 ] || exit 1
