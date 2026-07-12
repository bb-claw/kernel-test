#!/bin/sh
# Verify /proc/slabinfo is present and populated.
# Exercises the slab allocator (Clang allocation token changes in 7.2).
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -r /proc/slabinfo ]; then
    skip "/proc/slabinfo not available (CONFIG_SLUB_DEBUG or slab proc support may be off)"
    exit 0
fi

line_count=$(wc -l < /proc/slabinfo)
if [ "$line_count" -gt 2 ]; then
    ok "/proc/slabinfo has $line_count entries"
else
    fail "/proc/slabinfo exists but has too few entries ($line_count lines)"
fi

[ $fails -eq 0 ] || exit 1
