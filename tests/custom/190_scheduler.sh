#!/bin/sh
# Scheduler and process priority: load average, nice, context switches.
# Exercises kernel CFS scheduler, getpriority/setpriority syscalls, loadavg tracking.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# /proc/loadavg — CFS load-average tracking (requires CONFIG_PROC_FS)
# Format: load1 load5 load15 running/total lastpid
if [ -r /proc/loadavg ]; then
    loadavg=$(cat /proc/loadavg)
    ok "/proc/loadavg readable: $loadavg"
    if printf '%s\n' "$loadavg" \
            | grep -qE '^[0-9]+\.[0-9]+ [0-9]+\.[0-9]+ [0-9]+\.[0-9]+ [0-9]+/[0-9]+ [0-9]+$'; then
        ok "/proc/loadavg format valid (load1 load5 load15 running/total lastpid)"
    else
        fail "/proc/loadavg format unexpected: '$loadavg'"
    fi
else
    skip "/proc/loadavg not available"
fi

# nice — setpriority syscall: lower scheduling priority (positive nice value)
if nice -n 10 true 2>/dev/null; then
    ok "nice -n 10: below-default scheduling priority"
else
    fail "nice -n 10 failed"
fi

# nice negative — requires CAP_SYS_NICE; init in VM runs as root with full caps
if nice -n -5 true 2>/dev/null; then
    ok "nice -n -5: above-default scheduling priority (CAP_SYS_NICE)"
else
    skip "nice -n -5: CAP_SYS_NICE not available"
fi

# /proc/self/status — context switch counters written by the scheduler
for field in voluntary_ctxt_switches nonvoluntary_ctxt_switches; do
    if grep -q "^${field}:" /proc/self/status 2>/dev/null; then
        val=$(grep "^${field}:" /proc/self/status | awk '{print $2}')
        if [ -n "$val" ]; then
            ok "/proc/self/status: $field = $val"
        else
            fail "/proc/self/status: $field: empty value"
        fi
    else
        skip "/proc/self/status: $field not available"
    fi
done

# /proc/schedstat — per-CPU CFS run-queue statistics (CONFIG_SCHEDSTATS)
if [ -r /proc/schedstat ]; then
    if grep -qE '^cpu[0-9]' /proc/schedstat 2>/dev/null; then
        ok "/proc/schedstat: per-CPU scheduler statistics present"
    else
        fail "/proc/schedstat: unexpected or empty content"
    fi
else
    skip "/proc/schedstat not available (CONFIG_SCHEDSTATS may be disabled)"
fi

[ $fails -eq 0 ] || exit 1
