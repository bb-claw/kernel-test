#!/bin/sh
# setns path: enter a namespace via fd — different kernel code path from unshare(2).
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -e /proc/self/ns/uts ] || { skip "CONFIG_NAMESPACES=n (no /proc/self/ns/uts)"; exit 0; }

NS_UTS=/usr/bin/ns-uts

if [ ! -x "$NS_UTS" ]; then
    skip "setns: ns-uts binary not found (make bootstrap)"
    exit 0
fi

# ── self-setns: setns into own current namespace via fd ───────────────────

if $NS_UTS setns /proc/self/ns/uts > /dev/null 2>&1; then
    ok "setns: self-setns on /proc/self/ns/uts succeeded"
else
    fail "setns: self-setns on /proc/self/ns/uts failed"
fi

# ── cross-setns: enter a foreign UTS namespace via fd ─────────────────────

# Start a persistent process in a new UTS namespace
unshare -u sleep 10 &
bg=$!
# Allow the child to enter its namespace before we reference its ns path
sleep 1

if [ -e "/proc/$bg/ns/uts" ]; then
    self_inode=$(readlink /proc/self/ns/uts 2>/dev/null)
    target_inode=$(readlink "/proc/$bg/ns/uts" 2>/dev/null)
    if [ -n "$target_inode" ] && [ "$target_inode" != "$self_inode" ]; then
        if $NS_UTS setns "/proc/$bg/ns/uts" > /dev/null 2>&1; then
            ok "setns: entered foreign UTS namespace via ns-uts setns"
        else
            fail "setns: ns-uts setns into foreign UTS namespace failed"
        fi
    else
        skip "setns: child inode same as parent or unreadable — skipping cross-setns"
    fi
else
    skip "setns: background process exited before ns path was readable (timing)"
fi
kill "$bg" 2>/dev/null
wait "$bg" 2>/dev/null

# ── net namespace setns: exercises a separate setns(2) code path ──────────

[ -e /proc/self/ns/net ] || { [ $fails -eq 0 ] || exit 1; exit 0; }

NS_NET=/usr/bin/ns-net

if [ -x "$NS_NET" ]; then
    if $NS_NET clone > /dev/null 2>&1; then
        ok "setns: ns-net clone (net namespace setns path exercised)"
    else
        fail "setns: ns-net clone failed"
    fi
else
    skip "setns: ns-net binary not found (make bootstrap)"
fi

[ $fails -eq 0 ] || exit 1
