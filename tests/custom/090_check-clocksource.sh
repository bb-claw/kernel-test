#!/bin/sh
# Verify a clocksource was registered at boot.
# Catches regressions in the timer subsystem init path.
_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if ! command -v dmesg >/dev/null 2>&1; then
    skip "dmesg not available"
    exit 0
fi

if dmesg | grep -qi 'clocksource.*registered\|registered.*clocksource\|using clocksource'; then
    cs=$(dmesg | grep -i 'clocksource' | tail -1 | sed 's/.*\[.*\] //')
    ok "clocksource active: $cs"
else
    fail "no clocksource registration found in dmesg"
fi

[ $_fails -eq 0 ] || exit 1
