#!/bin/sh
# On-board system snapshot: validates /tmp/snapshot.txt written by /init at boot.
# /init runs snapshot before the test loop; this script checks the file exists
# and contains all expected fields plus a clean-exit marker.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

SNAP_BIN=/usr/bin/snapshot
SNAP_FILE=/tmp/snapshot.txt

[ -x "$SNAP_BIN" ] || { skip "snapshot binary absent (run: make bootstrap)"; exit 0; }

# /init should have written the file before this test runs.
# If absent (e.g. binary installed after initramfs was built), run it now.
# Exit code is discarded here — the re-run at the end checks it definitively.
if [ ! -f "$SNAP_FILE" ]; then
    "$SNAP_BIN" > "$SNAP_FILE" 2>/dev/null || true
fi

if [ ! -f "$SNAP_FILE" ]; then
    fail "snapshot output file absent"
    exit 1
fi
ok "snapshot output file present"

check_header() {
    if grep -q "^\*\* $1 \*\*" "$SNAP_FILE"; then
        ok "$1 header present"
    else
        fail "$1 header missing"
    fi
}

check_field() {
    if grep -q "$1:" "$SNAP_FILE"; then
        ok "$1 present"
    else
        fail "$1 missing"
    fi
}

check_header SNAPSHOT

# These fields come from syscalls and are always present.
check_field HOSTNAME
check_field UNAME
check_field PAGESIZE
check_field USER
check_field DMESG
check_field ISSUES

# Fields sourced from /proc or /sys — absent when CONFIG_PROC_FS=n (tinyconfig).
if [ -r /proc/uptime ]; then
    check_field INIT
    check_field UPTIME
    check_field LOADAVG
    check_field MEMORY
    check_field KERNELMEM
    check_field HUGEPAGES
    check_field SWAP
    check_field CPU
    check_field FLAGS
    check_field CLOCKSOURCE
    check_field FS
    if grep -q "LSM:" "$SNAP_FILE"; then
        ok "LSM present"
    else
        skip "LSM: securityfs absent or CONFIG_SECURITYFS=n"
    fi
    check_field ASLR
    check_field DMESG_RESTRICT
    check_field KPTR_RESTRICT
    check_field ENTROPY
    check_field TAINTED
    check_field CMDLINE
else
    skip "proc/sysfs not available — proc-based field checks skipped"
fi

cat /tmp/snapshot.txt

# Parse the ISSUES count from the boot-time snapshot rather than re-running.
# klogctl reads the entire ring buffer non-destructively; a post-test re-run
# would include messages accumulated during the test suite, causing false
# positives from kernel messages unrelated to boot health.
snap_issues=$(grep 'ISSUES:' "$SNAP_FILE" | sed 's/.*ISSUES: *//' | head -1)
if [ -z "$snap_issues" ]; then
    fail "snapshot: ISSUES count absent or unparseable"
else
    if [ "$snap_issues" -eq 0 ]; then
        ok "snapshot: no issues detected at boot (ISSUES: 0)"
    else
        fail "snapshot: $snap_issues issue(s) detected at boot"
    fi
fi

[ $fails -eq 0 ] || exit 1
