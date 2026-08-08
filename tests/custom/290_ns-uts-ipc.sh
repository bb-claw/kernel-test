#!/bin/sh
# UTS + IPC namespaces and the nsfs inode interface used by all namespace types.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -f /tests/ns-enabled ] || { skip "ns not enabled for this config (no /tests/ns-enabled)"; exit 0; }
[ -e /proc/self/ns/uts ] || { skip "CONFIG_NAMESPACES=n (no /proc/self/ns/uts)"; exit 0; }

NS_UTS=/usr/bin/ns-uts
NS_IPC=/usr/bin/ns-ipc

# ── nsfs interface: presence and format ──────────────────────────────────────

for ns in uts ipc pid mnt net; do
    path="/proc/self/ns/$ns"
    if [ -L "$path" ]; then
        target=$(readlink "$path" 2>/dev/null)
        if [ -n "$target" ]; then
            ok "nsfs $ns: $target"
        else
            fail "nsfs $ns: symlink target empty"
        fi
    else
        skip "nsfs $ns: not present (kernel config may be off)"
    fi
done

# optional types
for ns in user cgroup time; do
    if [ -L "/proc/self/ns/$ns" ]; then ok "nsfs $ns: present"; else skip "nsfs $ns: not present"; fi
done

# ── /proc/sys/user/ namespace limits ─────────────────────────────────────────

for knob in max_uts_namespaces max_ipc_namespaces max_pid_namespaces max_net_namespaces; do
    path="/proc/sys/user/$knob"
    if [ -r "$path" ]; then
        val=$(cat "$path")
        if [ "$val" -gt 0 ] 2>/dev/null; then
            ok "user/$knob: $val"
        else
            fail "user/$knob: unexpected value '$val'"
        fi
    else
        skip "user/$knob: not present"
    fi
done

# ── UTS: hostname isolation (Toybox unshare) ─────────────────────────────────

orig=$(hostname)
result=$(unshare -u sh -c 'hostname ns-test-290; hostname' 2>/dev/null)
if [ "$result" = "ns-test-290" ]; then
    ok "UTS: hostname isolated in unshare -u"
else
    if [ -z "$result" ]; then
        skip "UTS: unshare -u not functional (C binary tests cover it)"
    else
        fail "UTS: hostname not isolated (got '$result')"
    fi
fi

# Host hostname must be unchanged after child exited
now=$(hostname)
if [ "$now" = "$orig" ]; then
    ok "UTS: host hostname unchanged after child"
else
    fail "UTS: host hostname changed to '$now' (was '$orig')"
fi

# ── UTS: inode uniqueness (C binary) ─────────────────────────────────────────

if [ -x "$NS_UTS" ]; then
    if $NS_UTS clone > /dev/null 2>&1; then
        ok "UTS: clone inode change + hostname via ns-uts"
    else
        fail "UTS: ns-uts clone failed"
    fi
else
    skip "UTS: ns-uts binary not found (make bootstrap)"
fi

# ── IPC: inode uniqueness (C binary) ─────────────────────────────────────────

if [ -e /proc/self/ns/ipc ]; then
    if [ -x "$NS_IPC" ]; then
        if $NS_IPC clone > /dev/null 2>&1; then
            ok "IPC: clone inode change via ns-ipc"
        else
            fail "IPC: ns-ipc clone failed"
        fi
        if $NS_IPC semop > /dev/null 2>&1; then
            ok "IPC: semaphore isolated in new IPC ns"
        else
            fail "IPC: ns-ipc semop failed"
        fi
    else
        skip "IPC: ns-ipc binary not found (make bootstrap)"
    fi
else
    skip "IPC: CONFIG_IPC_NS=n"
fi

[ $fails -eq 0 ] || exit 1
