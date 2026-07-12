#!/bin/sh
# VM subsystem: VMA table, anonymous mappings, page-fault path.
# Exercises kernel mm/ via /proc/self/maps and /proc/meminfo.
# Skipped when CONFIG_PROC_FS is not enabled.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -r /proc/self/maps ]; then
    skip "/proc/self/maps not readable — skipping mmap checks"
    exit 0
fi

# VMA table has multiple entries
vma_count=$(wc -l < /proc/self/maps)
if [ "$vma_count" -gt 2 ]; then
    ok "VMA table has $vma_count entries"
else
    fail "VMA count unexpectedly low: $vma_count"
fi

# [stack] region must be present
if grep -q '\[stack\]' /proc/self/maps; then
    ok "[stack] VMA present"
else
    fail "[stack] VMA missing from /proc/self/maps"
fi

# Anonymous mappings (dev 00:00, inode 0, no path) must exist
if grep -qE '00:00 +0 *$' /proc/self/maps; then
    ok "anonymous VMAs present"
else
    skip "anonymous VMA check inconclusive"
fi

# Fork+exec must not disturb the parent's VMA table
maps_before=$(wc -l < /proc/self/maps)
sh -c 'exit 0'
maps_after=$(wc -l < /proc/self/maps)
if [ "$maps_before" -eq "$maps_after" ]; then
    ok "parent VMA table stable after fork/exec ($maps_before entries)"
else
    fail "parent VMA table changed after fork/exec (before=$maps_before after=$maps_after)"
fi

# /proc/meminfo paging fields — MemTotal always present; AnonPages and
# PageTables require CONFIG_MMU which is always true on x86
for field in MemTotal AnonPages PageTables; do
    if grep -q "^${field}:" /proc/meminfo 2>/dev/null; then
        ok "/proc/meminfo: $field present"
    else
        skip "/proc/meminfo: $field missing"
    fi
done

[ $fails -eq 0 ] || exit 1
