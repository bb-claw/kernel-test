#!/bin/sh
# Mount namespace: MS_MOVE, SB_I_NODEV, propagation, pivot_root.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -f /tests/ns-enabled ] || { skip "ns not enabled for this config (no /tests/ns-enabled)"; exit 0; }
[ -e /proc/self/ns/mnt ] || { skip "CONFIG_NAMESPACES=n (no /proc/self/ns/mnt)"; exit 0; }

NS_MOUNT=/usr/bin/ns-mount

# ── nsfs inode present and non-empty ─────────────────────────────────────

target=$(readlink /proc/self/ns/mnt 2>/dev/null)
if [ -n "$target" ]; then
    ok "mount: nsfs /proc/self/ns/mnt: $target"
else
    fail "mount: /proc/self/ns/mnt symlink target empty"
fi

# ── C binary: MS_MOVE, mknod, propagate, pivot_root ──────────────────────

if [ -x "$NS_MOUNT" ]; then
    if $NS_MOUNT move > /dev/null 2>&1; then
        ok "mount: MS_MOVE works in new mount ns"
    else
        fail "mount: ns-mount move failed (MS_MOVE regression)"
    fi

    if $NS_MOUNT mknod > /dev/null 2>&1; then
        ok "mount: mknod allowed on user-ns-mounted tmpfs (SB_I_NODEV ok)"
    else
        fail "mount: ns-mount mknod failed (SB_I_NODEV regression?)"
    fi

    if $NS_MOUNT propagate > /dev/null 2>&1; then
        ok "mount: shared->slave->private propagation tree ok (propagate_mnt no crash)"
    else
        fail "mount: ns-mount propagate failed (propagate_mnt regression?)"
    fi

    if $NS_MOUNT pivot > /dev/null 2>&1; then
        ok "mount: pivot_root succeeds in new mount ns"
    else
        fail "mount: ns-mount pivot failed"
    fi
else
    skip "mount: ns-mount binary not found (make bootstrap)"
fi

[ $fails -eq 0 ] || exit 1
