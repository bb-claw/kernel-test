#!/bin/sh
# Time namespace: clock offset, multi-threaded setns denial (CVE-2023-23586).
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# Time namespace is optional; skip silently if not built
[ -e /proc/self/ns/time ] || { skip "CONFIG_TIME_NS=n (no /proc/self/ns/time)"; exit 0; }

NS_TIME=/usr/bin/ns-time

# ── nsfs format check ─────────────────────────────────────────────────────

target=$(readlink /proc/self/ns/time 2>/dev/null)
if [ -n "$target" ]; then
    ok "nsfs time: $target"
else
    fail "nsfs time: /proc/self/ns/time symlink target empty"
fi

# ── /proc/self/timens_offsets readable ───────────────────────────────────

if [ -r /proc/self/timens_offsets ]; then
    ok "time: /proc/self/timens_offsets readable"
else
    skip "time: /proc/self/timens_offsets not present"
fi

# ── C binary: clock offset + multi-threaded setns denial ─────────────────

if [ -x "$NS_TIME" ]; then
    if $NS_TIME offset > /dev/null 2>&1; then
        ok "time: CLOCK_MONOTONIC +100s offset applied correctly in new time ns"
    else
        fail "time: ns-time offset failed (clock offset regression)"
    fi

    if $NS_TIME setns-mt > /dev/null 2>&1; then
        ok "time: setns CLONE_NEWTIME correctly denied from multi-threaded process (CVE-2023-23586 ok)"
    else
        fail "time: ns-time setns-mt failed (CVE-2023-23586 regression?)"
    fi
else
    skip "time: ns-time binary not found (make bootstrap)"
fi

[ $fails -eq 0 ] || exit 1
