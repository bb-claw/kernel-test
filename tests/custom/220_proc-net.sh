#!/bin/sh
# /proc/net: kernel network subsystem statistics (CONFIG_NET + CONFIG_PROC_FS).
# Checks that the per-interface, per-socket, and protocol-list files are
# present and contain recognisable content.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -d /proc/net ]; then
    skip "/proc/net absent (CONFIG_NET or CONFIG_PROC_FS may be off)"
    exit 0
fi

# /proc/net/dev — per-interface RX/TX counters; header line contains '|'.
if [ -r /proc/net/dev ]; then
    if grep -q '|' /proc/net/dev 2>/dev/null; then
        ok "/proc/net/dev: readable with interface table header"
    else
        fail "/proc/net/dev: unexpected or empty content"
    fi
else
    skip "/proc/net/dev: not available"
fi

# /proc/net/sockstat — socket pool counters; requires CONFIG_INET.
if [ -r /proc/net/sockstat ]; then
    if grep -q 'sockets' /proc/net/sockstat 2>/dev/null; then
        ok "/proc/net/sockstat: readable with socket counters"
    else
        fail "/proc/net/sockstat: unexpected content"
    fi
else
    skip "/proc/net/sockstat: not available (CONFIG_INET may be off)"
fi

# /proc/net/protocols — registered protocol list; header line has 'protocol'.
if [ -r /proc/net/protocols ]; then
    if grep -q 'protocol' /proc/net/protocols 2>/dev/null; then
        ok "/proc/net/protocols: readable"
    else
        fail "/proc/net/protocols: unexpected content"
    fi
else
    skip "/proc/net/protocols: not available"
fi

# /proc/net/if_inet6 — only exists when IPv6 is on AND an IPv6 interface is
# configured; absence is normal in a minimal VM, so skip rather than fail.
if [ -r /proc/net/if_inet6 ]; then
    ok "/proc/net/if_inet6: present (IPv6 enabled)"
else
    skip "/proc/net/if_inet6: absent (CONFIG_IPV6 off or no IPv6 interface)"
fi

[ $fails -eq 0 ] || exit 1
