#!/bin/sh
# inotify: filesystem change notification subsystem (CONFIG_INOTIFY_USER).
# Checks /proc/sys/fs/inotify limit knobs — confirms the subsystem compiled
# in and initialized with sane defaults.  Actual inotify_init/add_watch
# syscall testing requires a helper binary not present in the Toybox initramfs.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -d /proc/sys/fs/inotify ]; then
    skip "inotify not available (CONFIG_INOTIFY_USER may be off or /proc not mounted)"
    exit 0
fi

for key in max_queued_events max_user_instances max_user_watches; do
    if [ -r "/proc/sys/fs/inotify/$key" ]; then
        val=$(cat "/proc/sys/fs/inotify/$key" 2>/dev/null || true)
        if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
            ok "inotify/$key = $val"
        else
            fail "inotify/$key: unexpected value '${val:-empty}'"
        fi
    else
        fail "inotify/$key: not present under /proc/sys/fs/inotify"
    fi
done

[ $fails -eq 0 ] || exit 1
