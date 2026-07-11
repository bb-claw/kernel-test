#!/bin/sh
# Verify /proc/interrupts is readable and populated.
# Targets the /proc/interrupts rework in 7.2 (performance rewrite).
_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -r /proc/interrupts ]; then
    skip "/proc/interrupts not available (CONFIG_PROC_FS may be off)"
    exit 0
fi

grep -qE '^[[:space:]]*[0-9]+:' /proc/interrupts \
    && ok "/proc/interrupts readable with interrupt entries" \
    || fail "/proc/interrupts exists but contains no numbered entries"

[ $_fails -eq 0 ] || exit 1
