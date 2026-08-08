#!/bin/sh
# PID namespace: PID=1 isolation in new ns, init-death cascade SIGKILL.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -f /tests/ns-enabled ] || { skip "ns not enabled for this config (no /tests/ns-enabled)"; exit 0; }
[ -e /proc/self/ns/pid ] || { skip "CONFIG_PID_NS=n (no /proc/self/ns/pid)"; exit 0; }

NS_PID=/usr/bin/ns-pid

# ── /proc/sys/user namespace limits ──────────────────────────────────────

path=/proc/sys/user/max_pid_namespaces
if [ -r "$path" ]; then
    val=$(cat "$path")
    if [ "$val" -gt 0 ] 2>/dev/null; then
        ok "user/max_pid_namespaces: $val"
    else
        fail "user/max_pid_namespaces: unexpected value '$val'"
    fi
else
    skip "user/max_pid_namespaces: not present"
fi

# ── Toybox unshare -fp: new PID namespace inode ───────────────────────────

self_inode=$(readlink /proc/self/ns/pid 2>/dev/null)
child_inode=$(unshare -fp sh -c 'readlink /proc/self/ns/pid' 2>/dev/null)
if [ -n "$child_inode" ] && [ "$child_inode" != "$self_inode" ]; then
    ok "PID: inode changes in new pid ns (unshare -fp)"
else
    if [ -z "$child_inode" ]; then
        skip "PID: unshare -fp not functional (C binary tests cover it)"
    else
        fail "PID: inode unchanged after unshare -fp (got '$child_inode')"
    fi
fi

# ── C binary: PID=1 and NSpid verification ───────────────────────────────

if [ -x "$NS_PID" ]; then
    if $NS_PID clone > /dev/null 2>&1; then
        ok "PID: clone PID=1 + NSpid entries verified via ns-pid"
    else
        fail "PID: ns-pid clone failed"
    fi

    if $NS_PID init-death > /dev/null 2>&1; then
        ok "PID: init-death cascade SIGKILL verified"
    else
        fail "PID: ns-pid init-death failed"
    fi
else
    skip "PID: ns-pid binary not found (make bootstrap)"
fi

[ $fails -eq 0 ] || exit 1
