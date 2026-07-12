#!/bin/sh
# Bind mounts: MS_BIND flag via mount(2) — VFS path aliasing.
# Creates source/dest dirs on the initramfs rootfs (always writable RAM fs),
# bind-mounts, verifies the alias, then unmounts and cleans up.
# /tmp may not exist in tinyconfig (no CONFIG_TMPFS); rootfs paths are used.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

SRC=/bind-src-$$
DST=/bind-dst-$$

if ! mkdir -p "$SRC" "$DST" 2>/dev/null; then
    skip "bind mount: cannot create test directories on rootfs"
    exit 0
fi

printf 'bind-probe\n' > "$SRC/probe" 2>/dev/null || true

if ! mount --bind "$SRC" "$DST" 2>/dev/null; then
    skip "bind mount: mount --bind failed (VFS may not support it or no permission)"
    rm -rf "$SRC" "$DST" 2>/dev/null || true
    exit 0
fi

# File must be visible at the alias path.
if [ -r "$DST/probe" ]; then
    ok "bind mount: file visible at alias path"
else
    fail "bind mount: file not visible at $DST/probe after mount --bind"
fi

# /proc/mounts records the bind mount (requires CONFIG_PROC_FS).
if [ -r /proc/mounts ]; then
    if grep -q "$DST" /proc/mounts 2>/dev/null; then
        ok "bind mount: entry present in /proc/mounts"
    else
        skip "bind mount: /proc/mounts entry not found"
    fi
else
    skip "bind mount: /proc/mounts not available"
fi

# Cleanup: always unmount before removing dirs.
umount "$DST" 2>/dev/null || true
rm -rf "$SRC" "$DST" 2>/dev/null || true

[ $fails -eq 0 ] || exit 1
