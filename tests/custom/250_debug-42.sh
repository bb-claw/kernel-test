#!/bin/sh
# Verify /proc/debug_42 returns "42" — confirms CONFIG_DEBUG_42 is built in
# and procfs is operational. Skips gracefully when CANARY=1 was not used.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -f /proc/debug_42 ]; then
    skip "debug_42: /proc/debug_42 absent (CONFIG_DEBUG_42 not built in — rebuild with CANARY=1)"
    exit 0
fi

val=$(cat /proc/debug_42)
[ "$val" = "42" ] \
    && ok "debug_42: /proc/debug_42 returned '42'" \
    || fail "debug_42: expected '42', got '$val'"

[ $fails -eq 0 ] || exit 1
