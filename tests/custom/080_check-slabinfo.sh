#!/bin/sh
# Verify /proc/slabinfo is present and populated.
# Exercises the slab allocator (Clang allocation token changes in 7.2).
_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -r /proc/slabinfo ]; then
    skip "/proc/slabinfo not available (CONFIG_SLUB_DEBUG or slab proc support may be off)"
    exit 0
fi

line_count=$(wc -l < /proc/slabinfo)
[ "$line_count" -gt 2 ] \
    && ok "/proc/slabinfo has $line_count entries" \
    || fail "/proc/slabinfo exists but has too few entries ($line_count lines)"

[ $_fails -eq 0 ] || exit 1
