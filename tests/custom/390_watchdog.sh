#!/bin/sh
# Watchdog subsystem: device node, sysfs enumeration, magic-close write,
# running-config verification. Primary: /dev/watchdog + /sys/class/watchdog/*.
# Bonus: softlockup sysctl if CONFIG_SOFTLOCKUP_DETECTOR=y (not set in defconfig).
# Skip when watchdog device is absent (tinyconfig, allnoconfig, bare defconfig).
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# ── Softlockup watchdog (opportunistic) ──────────────────────────────────────
# CONFIG_SOFTLOCKUP_DETECTOR=n in all tested defconfigs; absent is not a failure.
wdog_sysctl=/proc/sys/kernel/watchdog
if [ -r "$wdog_sysctl" ]; then
    ok "softlockup: $wdog_sysctl readable"
    val=$(cat "$wdog_sysctl")
    if [ "$val" = "1" ] || [ "$val" = "0" ]; then
        ok "softlockup: enabled=$val"
    else
        fail "softlockup: unexpected value '$val' in $wdog_sysctl"
    fi
    if [ -r /proc/sys/kernel/watchdog_thresh ]; then
        thresh=$(cat /proc/sys/kernel/watchdog_thresh)
        ok "softlockup: watchdog_thresh=${thresh}s"
    fi
else
    skip "softlockup: $wdog_sysctl absent (CONFIG_SOFTLOCKUP_DETECTOR not set)"
fi

# ── Device watchdog location ──────────────────────────────────────────────────
# WATCHDOG_DEV env var: override device path for CI skip-guard testing (set to
# /nonexistent). Checked for existence before WD is set — a nonexistent override
# keeps WD empty, triggering the device-absent skip without touching the host watchdog.
WD=""
wd_override="${WATCHDOG_DEV:-}"
if [ -n "$wd_override" ]; then
    if [ -e "$wd_override" ]; then
        WD="$wd_override"
    fi
elif [ -e /dev/watchdog ]; then
    WD=/dev/watchdog
else
    if [ -e /dev/watchdog0 ]; then
        WD=/dev/watchdog0
    fi
fi

if [ -z "$WD" ]; then
    skip "device: /dev/watchdog absent (CONFIG_WATCHDOG/SOFT_WATCHDOG not built in)"
else
    ok "device: $WD present"

    if [ -c "$WD" ]; then
        ok "device: $WD is a character device"
    else
        fail "device: $WD exists but is not a character device"
    fi

    # ── Determine major:minor of $WD for sysfs correlation ───────────────────
    # ls -l output for char device: "crw... MAJOR, MINOR DATE TIME NAME"
    # sed removes comma and collapses spaces so field 5=major, field 6=minor.
    wd_ls=$(ls -l "$WD" | sed 's/,/ /g;s/  */ /g')
    wd_major=$(printf '%s\n' "$wd_ls" | cut -d' ' -f5)
    wd_minor=$(printf '%s\n' "$wd_ls" | cut -d' ' -f6)
    if [ -z "$wd_major" ] || [ -z "$wd_minor" ]; then
        WD_DEVNO=""
        ok "sysfs: ls -l parse failed for $WD — major:minor unknown, nowayout=0 default"
    else
        WD_DEVNO="${wd_major}:${wd_minor}"
    fi

    # ── sysfs enumeration (CONFIG_WATCHDOG_SYSFS=y) ───────────────────────────
    # Enumerate all registered watchdog devices. In QEMU: typically only watchdog0
    # (softdog). On VisionFive 2: may include watchdog0=softdog + watchdog1=starfive
    # (or whichever probes first). Correlate $WD by major:minor to find correct nowayout.
    WD_SYS_DIR=/sys/class/watchdog
    nowayout=0
    found_wd=0
    wd_matched=0
    if [ -d "$WD_SYS_DIR" ]; then
        for WD_SYS in "$WD_SYS_DIR"/watchdog*; do
            [ -d "$WD_SYS" ] || continue
            found_wd=$((found_wd + 1))
            wdname=$(basename "$WD_SYS")
            ok "sysfs: $wdname registered"
            if [ -r "$WD_SYS/identity" ]; then
                ident=$(cat "$WD_SYS/identity")
                ok "sysfs: $wdname identity='$ident'"
            fi
            if [ -r "$WD_SYS/timeout" ]; then
                tout=$(cat "$WD_SYS/timeout")
                ok "sysfs: $wdname timeout=${tout}s"
            fi
            if [ -r "$WD_SYS/state" ]; then
                state=$(cat "$WD_SYS/state")
                ok "sysfs: $wdname state=$state"
            fi
            if [ -r "$WD_SYS/nowayout" ]; then
                noa=$(cat "$WD_SYS/nowayout")
                ok "sysfs: $wdname nowayout=$noa"
                if [ -r "$WD_SYS/dev" ] && [ -n "$WD_DEVNO" ]; then
                    sysfs_dev=$(cat "$WD_SYS/dev")
                    if [ "$sysfs_dev" = "$WD_DEVNO" ]; then
                        nowayout="$noa"
                        wd_matched=1
                        ok "sysfs: $wdname matches $WD (dev=$sysfs_dev)"
                    fi
                fi
            fi
        done
        if [ "$found_wd" -gt 0 ]; then
            ok "sysfs: $found_wd watchdog device(s) enumerated"
            if [ "$wd_matched" -eq 0 ] && [ -n "$WD_DEVNO" ]; then
                ok "sysfs: no major:minor match for $WD_DEVNO — nowayout=0 default"
            fi
        else
            skip "sysfs: no entries in $WD_SYS_DIR (CONFIG_WATCHDOG_SYSFS not set)"
        fi
    else
        skip "sysfs: $WD_SYS_DIR absent (CONFIG_WATCHDOG_SYSFS not set)"
    fi

    # ── Magic-close write test ─────────────────────────────────────────────────
    # Open /dev/watchdog, write "V" (keepalive + disarm flag), close fd.
    # Starts timer on open, immediately disarms on close — safe when NOWAYOUT=0.
    # NOWAYOUT=1: once opened, timer cannot be stopped; skip to avoid VM reboot.
    # Write failure: in the VM we run as PID 1 (root), so EACCES means real misconfiguration.
    if [ "$nowayout" = "1" ]; then
        skip "device: magic-close skipped (NOWAYOUT=1 — timer cannot be disarmed)"
    else
        if printf 'V' > "$WD" 2>/dev/null; then
            ok "device: magic-close write succeeded (timer disarmed)"
        else
            fail "device: write to $WD failed"
        fi
    fi
fi

# ── Running config verification via /proc/config.gz (opportunistic) ───────────
# Requires CONFIG_IKCONFIG_PROC=y — present in defconfig/kunitconfig, absent in
# tinyconfig/allnoconfig. Confirms SOFT_WATCHDOG is what provided the device.
if [ -r /proc/config.gz ]; then
    gunzip -c /proc/config.gz > /tmp/watchdog-running.config 2>/dev/null
    if grep -q '^CONFIG_WATCHDOG=y' /tmp/watchdog-running.config; then
        ok "config: CONFIG_WATCHDOG=y in running kernel"
    else
        if [ -n "$WD" ]; then
            fail "config: $WD present but CONFIG_WATCHDOG=n in running kernel"
        else
            skip "config: CONFIG_WATCHDOG=y not confirmed via /proc/config.gz"
        fi
    fi
    if grep -q '^CONFIG_SOFT_WATCHDOG=y' /tmp/watchdog-running.config; then
        ok "config: CONFIG_SOFT_WATCHDOG=y in running kernel"
    else
        skip "config: CONFIG_SOFT_WATCHDOG not y (hardware watchdog or not built)"
    fi
else
    skip "config: /proc/config.gz absent (CONFIG_IKCONFIG_PROC not set)"
fi

[ $fails -eq 0 ] || exit 1
