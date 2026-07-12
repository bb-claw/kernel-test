#!/bin/sh
# Verify a clocksource was registered at boot.
# Catches regressions in the timer subsystem init path.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if ! command -v dmesg >/dev/null 2>&1; then
    skip "dmesg not available"
    exit 0
fi

if dmesg | grep -qi 'Switched to clocksource\|clocksource.*registered\|registered.*clocksource\|using clocksource'; then
    cs=$(dmesg | grep -i 'Switched to clocksource\|clocksource.*registered\|using clocksource' | tail -1)
    ok "clocksource active: $cs"
else
    fail "no active clocksource found in dmesg"
fi

[ $fails -eq 0 ] || exit 1
