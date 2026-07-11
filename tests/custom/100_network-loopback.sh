#!/bin/sh
# Test loopback network — exercises CONFIG_NET, CONFIG_INET, loopback driver,
# and ICMP echo end-to-end.

_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -d /proc/net ] && [ ! -d /sys/class/net ]; then
    skip "no network support (CONFIG_NET likely off)"
    exit 0
fi

# Bring up loopback — try ip first (iproute2/busybox), then ifconfig
if ip link set lo up 2>/dev/null; then
    ok "loopback interface up (ip)"
elif ifconfig lo up 2>/dev/null; then
    ok "loopback interface up (ifconfig)"
else
    skip "cannot bring up loopback — ip/ifconfig unavailable"
    exit 0
fi

# Verify loopback address is present.
# Avoid \<newline> continuation — Toybox sh 0.8.9 passes an empty word to grep.
_has_addr=0
if ip addr show lo 2>/dev/null | grep -q '127\.0\.0\.1'; then
    _has_addr=1
elif ifconfig lo 2>/dev/null | grep -q '127\.0\.0\.1'; then
    _has_addr=1
fi
if [ "$_has_addr" -eq 1 ]; then
    ok "loopback has 127.0.0.1"
else
    skip "127.0.0.1 not configured on lo (CONFIG_INET may be off)"
    exit 0
fi

# ICMP echo — show ping output on failure for diagnosis
if ping -c1 -W2 127.0.0.1 >/dev/null 2>&1; then
    ok "ping 127.0.0.1"
else
    ping -c1 -W2 127.0.0.1 2>&1 | head -5 || true
    fail "ping 127.0.0.1 failed"
fi

[ $_fails -eq 0 ] || exit 1
