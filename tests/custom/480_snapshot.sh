#!/bin/sh
# On-board system snapshot: validates /tmp/snapshot.txt written by /init at boot.
# /init runs snapshot before the test loop; this script checks the file exists
# and contains all expected section headers plus a clean-exit marker.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

SNAP_BIN=/usr/bin/snapshot
SNAP_FILE=/tmp/snapshot.txt

[ -x "$SNAP_BIN" ] || { skip "snapshot binary absent (run: make bootstrap)"; exit 0; }

# /init should have written the file before this test runs.
# If absent (e.g. binary installed after initramfs was built), run it now.
if [ ! -f "$SNAP_FILE" ]; then
    "$SNAP_BIN" > "$SNAP_FILE" 2>/dev/null || true
fi

if [ ! -f "$SNAP_FILE" ]; then
    fail "snapshot output file absent"
    exit 1
fi
ok "snapshot output file present"

check_section() {
    if grep -q "^=== $1 ===" "$SNAP_FILE"; then
        ok "$1 section present"
    else
        fail "$1 section missing"
    fi
}

check_section SNAPSHOT
check_section UNAME
check_section UPTIME
check_section CMDLINE
check_section TAINTED
check_section DMESG
check_section MEMINFO

if grep -q "^snapshot_ok=1" "$SNAP_FILE"; then
    ok "snapshot_ok=1 (clean exit)"
else
    fail "snapshot_ok=1 missing (snapshot may have crashed mid-run)"
fi

[ $fails -eq 0 ] || exit 1
