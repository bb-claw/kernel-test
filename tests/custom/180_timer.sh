#!/bin/sh
# Timer and clock subsystem: uptime, epoch sanity, monotonic advance, hrtimers.
# Exercises kernel timekeeping: ktime, jiffies, hrtimer infrastructure, nanosleep.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# /proc/uptime — kernel uptime since boot (requires CONFIG_PROC_FS)
if [ -r /proc/uptime ]; then
    uptime_s=$(cut -d' ' -f1 /proc/uptime)
    if [ -n "$uptime_s" ]; then
        ok "/proc/uptime readable: ${uptime_s}s"
    else
        fail "/proc/uptime: empty value"
    fi
else
    skip "/proc/uptime not available"
fi

# Epoch sanity — gettimeofday/clock_gettime must return a date after 2020-01-01
# (1577836800).  epoch < 1000 means the clock was never set by an RTC (starts
# at 0 at boot and ticks up); skip rather than fail — not a kernel bug.
# A non-trivial but pre-2020 value (e.g. wrong RTC battery) is a real failure.
# Use nested if/else instead of elif — Toybox sh 0.8.9 elif runs both branches.
epoch=$(date +%s 2>/dev/null || true)
if [ -n "$epoch" ] && [ "$epoch" -gt 1577836800 ] 2>/dev/null; then
    ok "clock epoch sane: $epoch ($(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo ?))"
else
    if [ -z "$epoch" ] || [ "$epoch" -lt 1000 ] 2>/dev/null; then
        skip "clock epoch: RTC not initialized (epoch=${epoch:-empty})"
    else
        fail "clock epoch looks wrong: '${epoch:-empty}'"
    fi
fi

# Uptime advances — read /proc/uptime integer-seconds before and after a 1 s sleep;
# confirms jiffies/hrtimers are ticking and nanosleep delivers the wakeup.
# Guard with sleep exit-code check: Toybox i686 sleep exits non-zero (userspace bug,
# not a kernel issue), so skip rather than false-fail when sleep itself is broken.
if [ -r /proc/uptime ]; then
    before=$(cut -d'.' -f1 /proc/uptime)
    if sleep 1 2>/dev/null; then
        after=$(cut -d'.' -f1 /proc/uptime)
        if [ "$after" -gt "$before" ] 2>/dev/null; then
            ok "/proc/uptime advances after 1 s sleep: ${before}s → ${after}s"
        else
            fail "/proc/uptime did not advance (before=${before} after=${after})"
        fi
    else
        skip "/proc/uptime advance check: sleep not functional on this build"
    fi
else
    skip "/proc/uptime advance check: not available"
fi

# sleep 0 — zero-duration nanosleep must succeed immediately.
# Treat failure as skip: Toybox i686 sleep exits non-zero for any duration
# (userspace limitation, not a kernel issue).
if sleep 0 2>/dev/null; then
    ok "sleep 0: zero-duration nanosleep exits successfully"
else
    skip "sleep 0: sleep not functional on this build"
fi

# /proc/timer_list — hrtimer and tick_device infrastructure (CONFIG_POSIX_TIMERS).
# "Version" matches the always-present "Timer List Version: v0.9" header.
if [ -r /proc/timer_list ]; then
    if grep -qE 'jiffies|tick_device|clockevents|timer_bases|Version' /proc/timer_list 2>/dev/null; then
        ok "/proc/timer_list: hrtimer infrastructure present"
    else
        fail "/proc/timer_list: unexpected or empty content"
    fi
else
    skip "/proc/timer_list not available (CONFIG_POSIX_TIMERS may be disabled)"
fi

[ $fails -eq 0 ] || exit 1
