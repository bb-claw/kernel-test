#!/bin/sh
# Verify kernel identity and sysctl tunables exposed via /proc/sys/kernel.
# Skipped when procfs is not available.

_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }
info() { printf 'info: %s\n' "$*"; }

SYSCTL=/proc/sys/kernel
if [ ! -d "$SYSCTL" ]; then
    skip "procfs not mounted — skipping check-kernel"
    exit 0
fi

# osrelease — version string must start with a digit
if [ -r "$SYSCTL/osrelease" ]; then
    ver=$(cat "$SYSCTL/osrelease")
    case "$ver" in
        [0-9]*) ok "osrelease=$ver" ;;
        *)      fail "osrelease malformed: $ver" ;;
    esac
else
    fail "$SYSCTL/osrelease not readable"
fi

# ostype — must be "Linux"
if [ -r "$SYSCTL/ostype" ]; then
    ost=$(cat "$SYSCTL/ostype")
    if [ "$ost" = "Linux" ]; then
        ok "ostype=Linux"
    else
        fail "ostype unexpected: $ost"
    fi
else
    skip "$SYSCTL/ostype not readable"
fi

# pid_max — must be a positive integer
if [ -r "$SYSCTL/pid_max" ]; then
    pidmax=$(cat "$SYSCTL/pid_max")
    if [ -n "$pidmax" ] && [ "$pidmax" -gt 0 ]; then
        ok "pid_max=$pidmax"
    else
        fail "pid_max invalid: $pidmax"
    fi
else
    skip "$SYSCTL/pid_max not readable"
fi

# panic — timeout after kernel panic (we set it to 5 in QEMU cmdline)
if [ -r "$SYSCTL/panic" ]; then
    pval=$(cat "$SYSCTL/panic")
    ok "panic_timeout=$pval"
else
    skip "$SYSCTL/panic not readable"
fi

# hostname
if [ -r "$SYSCTL/hostname" ]; then
    hn=$(cat "$SYSCTL/hostname")
    if [ -n "$hn" ]; then
        ok "hostname=$hn"
    else
        fail "hostname is empty"
    fi
else
    skip "$SYSCTL/hostname not readable"
fi

# Random entropy — important for cryptographic subsystem health
if [ -r /proc/sys/kernel/random/entropy_avail ]; then
    ent=$(cat /proc/sys/kernel/random/entropy_avail)
    info "entropy_avail=$ent bits"
else
    skip "entropy_avail not readable"
fi

# Architecture — must match expected x86 or i386
if [ -r "$SYSCTL/arch" ] || [ -r /proc/cpuinfo ]; then
    arch=$(uname -m 2>/dev/null || echo unknown)
    case "$arch" in
        x86_64|i386|i686) ok "arch=$arch" ;;
        *)                  fail "unexpected arch: $arch" ;;
    esac
fi

[ $_fails -eq 0 ] || exit 1
