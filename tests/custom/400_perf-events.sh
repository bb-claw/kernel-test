#!/bin/sh
# perf_event_open syscall path — PERF_TYPE_SOFTWARE/TASK_CLOCK via C helper.
# Works in QEMU TCG (no hardware PMU needed); catches riscv PMU regressions.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

PERF_BIN=/usr/bin/perf-event

[ -x "$PERF_BIN" ] || { skip "perf-event binary absent (run: make bootstrap)"; exit 0; }

[ -r /proc/sys/kernel/perf_event_paranoid ] || {
    skip "perf_event_paranoid absent (CONFIG_PERF_EVENTS=n)"; exit 0
}
ok "perf_event_paranoid readable"

if [ -r /proc/config.gz ]; then
    zcat /proc/config.gz 2>/dev/null > /tmp/kconfig-perf.txt
    if grep -q 'CONFIG_PERF_EVENTS=y' /tmp/kconfig-perf.txt; then
        ok "CONFIG_PERF_EVENTS=y"
    else
        skip "CONFIG_PERF_EVENTS=n (confirmed via /proc/config.gz)"; exit 0
    fi
fi

# Run helper; redirect to file to avoid if-out=$(...) Toybox pitfall.
"$PERF_BIN" > /tmp/perf-count.txt 2>/tmp/perf-err.txt
rc=$?
count=$(cat /tmp/perf-count.txt)

if [ "$rc" -eq 0 ] && [ "$count" -gt 0 ] 2>/dev/null; then
    ok "perf_event_open: TASK_CLOCK count=$count ns"
else
    err=$(cat /tmp/perf-err.txt)
    fail "perf_event_open failed (rc=$rc count='$count' err='$err')"
fi

[ $fails -eq 0 ] || exit 1
