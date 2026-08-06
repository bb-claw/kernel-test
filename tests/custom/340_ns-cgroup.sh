#!/bin/sh
# Cgroup namespace: scoping, release-agent restriction (CVE-2022-0492).
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -e /proc/self/ns/cgroup ] || { skip "CONFIG_CGROUP_NS=n (no /proc/self/ns/cgroup)"; exit 0; }

NS_CGROUP=/usr/bin/ns-cgroup

# ── nsfs inode present and non-empty ─────────────────────────────────────

target=$(readlink /proc/self/ns/cgroup 2>/dev/null)
if [ -n "$target" ]; then
    ok "cgroup: nsfs /proc/self/ns/cgroup: $target"
else
    fail "cgroup: /proc/self/ns/cgroup symlink target empty"
fi

# ── /sys/fs/cgroup presence ───────────────────────────────────────────────

if [ -d /sys/fs/cgroup ]; then
    ok "cgroup: /sys/fs/cgroup present"
    if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
        ok "cgroup: cgroup.controllers readable (cgroup v2)"
    else
        skip "cgroup: cgroup.controllers not readable (cgroup v1 or not mounted)"
    fi
else
    skip "cgroup: /sys/fs/cgroup not present"
fi

# ── C binary: scoping + release-agent restriction ────────────────────────

if [ -x "$NS_CGROUP" ]; then
    if $NS_CGROUP scoping > /dev/null 2>&1; then
        ok "cgroup: ns inode + /sys/fs/cgroup accessible in new cgroup ns"
    else
        fail "cgroup: ns-cgroup scoping failed"
    fi

    if $NS_CGROUP release-agent > /dev/null 2>&1; then
        ok "cgroup: release-agent write denied from user ns (CVE-2022-0492 ok)"
    else
        fail "cgroup: ns-cgroup release-agent failed (CVE-2022-0492 regression?)"
    fi
else
    skip "cgroup: ns-cgroup binary not found (make bootstrap)"
fi

[ $fails -eq 0 ] || exit 1
