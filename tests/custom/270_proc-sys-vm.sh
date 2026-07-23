#!/bin/sh
# /proc/sys/vm sysctl namespace: range-validate the most stable knobs and
# sanity-check page allocator zone accounting via /proc/buddyinfo + /proc/zoneinfo.
# Skips when CONFIG_PROC_FS is disabled (tinyconfig, allnoconfig).

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -r /proc/sys/vm/overcommit_memory ] || { skip "proc-sys-vm: procfs absent or vm sysctl unavailable"; exit 0; }

# ── overcommit_memory: kernel enforces 0/1/2 ─────────────────────────────────

val=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)
case "$val" in
    0|1|2) ok "overcommit_memory=$val (valid: 0/1/2)" ;;
    *)     fail "overcommit_memory='$val' outside valid range {0,1,2}" ;;
esac

# ── swappiness: kernel enforces 0–200 ────────────────────────────────────────

val=$(cat /proc/sys/vm/swappiness 2>/dev/null)
if [ -n "$val" ] && [ "$val" -ge 0 ] 2>/dev/null && [ "$val" -le 200 ] 2>/dev/null; then
    ok "swappiness=$val (valid: 0–200)"
else
    fail "swappiness='$val' outside valid range 0–200"
fi

# ── dirty_ratio: kernel enforces 1–100 ───────────────────────────────────────

val=$(cat /proc/sys/vm/dirty_ratio 2>/dev/null)
if [ -n "$val" ] && [ "$val" -ge 1 ] 2>/dev/null && [ "$val" -le 100 ] 2>/dev/null; then
    ok "dirty_ratio=$val (valid: 1–100)"
else
    fail "dirty_ratio='$val' outside valid range 1–100"
fi

# ── dirty_background_ratio: kernel enforces 1–100 ────────────────────────────

val=$(cat /proc/sys/vm/dirty_background_ratio 2>/dev/null)
if [ -n "$val" ] && [ "$val" -ge 1 ] 2>/dev/null && [ "$val" -le 100 ] 2>/dev/null; then
    ok "dirty_background_ratio=$val (valid: 1–100)"
else
    fail "dirty_background_ratio='$val' outside valid range 1–100"
fi

# ── /proc/buddyinfo: page allocator zone accounting ──────────────────────────

if [ -r /proc/buddyinfo ]; then
    if grep -q "^Node" /proc/buddyinfo 2>/dev/null; then
        ok "/proc/buddyinfo: Node line present"
    else
        fail "/proc/buddyinfo: readable but no Node line found"
    fi
else
    skip "/proc/buddyinfo: not available (CONFIG_PROC_FS may be partial)"
fi

# ── /proc/zoneinfo: memory zone details ──────────────────────────────────────

if [ -r /proc/zoneinfo ]; then
    if grep -q "^Node 0" /proc/zoneinfo 2>/dev/null; then
        ok "/proc/zoneinfo: Node 0 present"
    else
        fail "/proc/zoneinfo: readable but Node 0 not found"
    fi
else
    skip "/proc/zoneinfo: not available"
fi

[ $fails -eq 0 ] || exit 1
