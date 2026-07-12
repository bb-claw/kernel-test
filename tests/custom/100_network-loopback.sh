#!/bin/sh
# Test loopback network — exercises CONFIG_NET, CONFIG_INET, loopback driver,
# and ICMP echo end-to-end.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -d /proc/net ] && [ ! -d /sys/class/net ]; then
    skip "no network support (CONFIG_NET likely off)"
    exit 0
fi

# Bring up loopback — Toybox provides ifconfig, not ip
if ifconfig lo up 2>/dev/null; then
    ok "loopback interface up"
else
    skip "cannot bring up loopback (ifconfig unavailable or CONFIG_NET off)"
    exit 0
fi

# Verify loopback address is present
if ifconfig lo 2>/dev/null | grep -q '127\.0\.0\.1'; then
    ok "loopback has 127.0.0.1"
else
    skip "127.0.0.1 not configured on lo (CONFIG_INET may be off)"
    exit 0
fi

# ICMP echo — Toybox ping uses SOCK_DGRAM (not raw); allow GID 0 via sysctl
printf '0\t2147483647\n' > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true
if ping -c1 -W2 127.0.0.1 >/dev/null 2>&1; then
    ok "ping 127.0.0.1"
else
    ping -c1 -W2 127.0.0.1 2>&1 | head -5 || true
    fail "ping 127.0.0.1 failed"
fi

[ $fails -eq 0 ] || exit 1
