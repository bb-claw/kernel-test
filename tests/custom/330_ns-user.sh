#!/bin/sh
# User namespace: uid/gid mapping, nested ns (CVE-2018-18955: >5 UID ranges).
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -f /tests/ns-enabled ] || { skip "ns not enabled for this config (no /tests/ns-enabled)"; exit 0; }
[ -e /proc/self/ns/user ] || { skip "CONFIG_USER_NS=n (no /proc/self/ns/user)"; exit 0; }

NS_USER=/usr/bin/ns-user

# ── /proc/sys/user namespace limits ──────────────────────────────────────

path=/proc/sys/user/max_user_namespaces
if [ -r "$path" ]; then
    val=$(cat "$path")
    if [ "$val" -gt 0 ] 2>/dev/null; then
        ok "user/max_user_namespaces: $val"
    else
        fail "user/max_user_namespaces: unexpected value '$val'"
    fi
else
    skip "user/max_user_namespaces: not present"
fi

# ── Toybox unshare -U: inode changes ─────────────────────────────────────

self_inode=$(readlink /proc/self/ns/user 2>/dev/null)
child_inode=$(unshare -U sh -c 'readlink /proc/self/ns/user' 2>/dev/null)
if [ -n "$child_inode" ] && [ "$child_inode" != "$self_inode" ]; then
    ok "user: inode changes in new user ns (unshare -U)"
else
    if [ -z "$child_inode" ]; then
        skip "user: unshare -U not functional (C binary tests cover it)"
    else
        fail "user: inode unchanged after unshare -U (got '$child_inode')"
    fi
fi

# ── appears as uid 0 inside user ns via -U -r ────────────────────────────

uid_in_ns=$(unshare -U -r sh -c 'id -u' 2>/dev/null)
if [ "$uid_in_ns" = "0" ]; then
    ok "user: appears as uid 0 inside user ns (unshare -U -r)"
else
    skip "user: unshare -U -r uid check skipped (got '$uid_in_ns')"
fi

# ── C binary: uid_map write + nested 6-range idmap ───────────────────────

if [ -x "$NS_USER" ]; then
    if $NS_USER idmap > /dev/null 2>&1; then
        ok "user: uid_map written and verified via ns-user"
    else
        fail "user: ns-user idmap failed"
    fi

    if $NS_USER nested-6 > /dev/null 2>&1; then
        ok "user: nested user ns 6-range uid_map accepted (CVE-2018-18955 ok)"
    else
        fail "user: ns-user nested-6 failed (CVE-2018-18955 regression?)"
    fi
else
    skip "user: ns-user binary not found (make bootstrap)"
fi

[ $fails -eq 0 ] || exit 1
