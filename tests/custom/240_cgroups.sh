#!/bin/sh
# cgroups v2: unified resource control hierarchy.
# Checks /sys/fs/cgroup v2 API: controllers list and process membership.
# No child cgroup is created to avoid cleanup complexity.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

CGROOT=/sys/fs/cgroup

if [ ! -d "$CGROOT" ]; then
    skip "cgroups: /sys/fs/cgroup not mounted (CONFIG_CGROUPS may be off)"
    exit 0
fi

# cgroup.controllers is v2-specific; its absence means v1-only or not mounted.
if [ ! -r "$CGROOT/cgroup.controllers" ]; then
    skip "cgroup v2 not active (cgroup.controllers absent; v1-only or not unified)"
    exit 0
fi

ok "cgroup v2 unified hierarchy mounted at $CGROOT"

# cgroup.controllers: space-separated list of available resource controllers.
controllers=$(cat "$CGROOT/cgroup.controllers" 2>/dev/null || true)
if [ -n "$controllers" ]; then
    ok "cgroup.controllers: $controllers"
else
    skip "cgroup.controllers: empty (no controllers delegated to root)"
fi

# cgroup.procs: lists PIDs in the root cgroup; should contain at least one.
if [ -r "$CGROOT/cgroup.procs" ]; then
    if grep -q '[0-9]' "$CGROOT/cgroup.procs" 2>/dev/null; then
        ok "cgroup.procs: readable and non-empty"
    else
        fail "cgroup.procs: empty — at least one PID should be present"
    fi
else
    skip "cgroup.procs: not available"
fi

# cgroup.subtree_control: which controllers are delegated to children.
if [ -r "$CGROOT/cgroup.subtree_control" ]; then
    subtree=$(cat "$CGROOT/cgroup.subtree_control" 2>/dev/null || true)
    ok "cgroup.subtree_control: '${subtree:-<empty>}'"
else
    skip "cgroup.subtree_control: not available"
fi

[ $fails -eq 0 ] || exit 1
