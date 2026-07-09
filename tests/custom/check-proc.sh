#!/bin/sh
# Verify /proc filesystem content.
# Skipped entirely when CONFIG_PROC_FS is not enabled (e.g. tinyconfig).

_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -d /proc ] || [ ! -r /proc/version ]; then
    skip "procfs not mounted — skipping check-proc"
    exit 0
fi

# /proc/version
grep -q "Linux" /proc/version \
    && ok "/proc/version" || fail "/proc/version missing or malformed"

# /proc/cpuinfo
if [ -r /proc/cpuinfo ]; then
    grep -qi "processor" /proc/cpuinfo \
        && ok "/proc/cpuinfo has processor entry" \
        || fail "/proc/cpuinfo: no processor entry"
else
    fail "/proc/cpuinfo not readable"
fi

# /proc/meminfo — MemTotal must be > 0
if [ -r /proc/meminfo ]; then
    mem=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    [ -n "$mem" ] && [ "$mem" -gt 0 ] \
        && ok "/proc/meminfo MemTotal=${mem}kB" \
        || fail "/proc/meminfo MemTotal is zero or missing"
else
    fail "/proc/meminfo not readable"
fi

# /proc/uptime
if [ -r /proc/uptime ]; then
    up=$(cut -d. -f1 /proc/uptime)
    [ -n "$up" ] \
        && ok "/proc/uptime=${up}s" || fail "/proc/uptime malformed"
else
    fail "/proc/uptime not readable"
fi

# /proc/cmdline — must contain console=
if [ -r /proc/cmdline ]; then
    grep -q "console=" /proc/cmdline \
        && ok "/proc/cmdline has console=" \
        || fail "/proc/cmdline missing console= (got: $(cat /proc/cmdline))"
else
    fail "/proc/cmdline not readable"
fi

# /proc/filesystems — confirm basic filesystem types present
if [ -r /proc/filesystems ]; then
    ok "/proc/filesystems readable"
else
    skip "/proc/filesystems not available"
fi

[ $_fails -eq 0 ] || exit 1
