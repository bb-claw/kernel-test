#!/bin/sh
# Verify /proc/debug_42 returns "42" — confirms CONFIG_DEBUG_42 is built in
# and procfs is operational. Skips gracefully when CANARY=1 was not used.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -f /proc/debug_42 ]; then
    skip "debug_42: /proc/debug_42 not available (CONFIG_DEBUG_42 or CONFIG_PROC_FS not built in — rebuild with CANARY=1)"
    exit 0
fi

val=$(cat /proc/debug_42)
if [ "$val" = "42" ]; then
    ok "debug_42: /proc/debug_42 returned '42'"
else
    fail "debug_42: expected '42', got '$val'"
fi

[ $fails -eq 0 ] || exit 1
