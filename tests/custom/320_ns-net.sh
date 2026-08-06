#!/bin/sh
# Network namespace: isolation, /proc/net per-ns view (init_net leak detection).
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -e /proc/self/ns/net ] || { skip "CONFIG_NET_NS=n (no /proc/self/ns/net)"; exit 0; }

NS_NET=/usr/bin/ns-net

# ── /proc/sys/user namespace limits ──────────────────────────────────────

path=/proc/sys/user/max_net_namespaces
if [ -r "$path" ]; then
    val=$(cat "$path")
    if [ "$val" -gt 0 ] 2>/dev/null; then
        ok "user/max_net_namespaces: $val"
    else
        fail "user/max_net_namespaces: unexpected value '$val'"
    fi
else
    skip "user/max_net_namespaces: not present"
fi

# ── Toybox unshare -n: inode changes ─────────────────────────────────────

self_inode=$(readlink /proc/self/ns/net 2>/dev/null)
child_inode=$(unshare -n sh -c 'readlink /proc/self/ns/net' 2>/dev/null)
if [ -n "$child_inode" ] && [ "$child_inode" != "$self_inode" ]; then
    ok "net: inode changes in new net ns (unshare -n)"
elif [ -z "$child_inode" ]; then
    skip "net: unshare -n not functional (C binary tests cover it)"
else
    fail "net: inode unchanged after unshare -n (got '$child_inode')"
fi

# ── C binary: inode change + /proc/net isolation ─────────────────────────

if [ -x "$NS_NET" ]; then
    if $NS_NET clone > /dev/null 2>&1; then
        ok "net: clone inode change via ns-net"
    else
        fail "net: ns-net clone failed"
    fi

    if $NS_NET proc-net > /dev/null 2>&1; then
        ok "net: /proc/net isolated in new net ns (no init_net leak)"
    else
        fail "net: ns-net proc-net failed (init_net leak regression?)"
    fi
else
    skip "net: ns-net binary not found (make bootstrap)"
fi

[ $fails -eq 0 ] || exit 1
