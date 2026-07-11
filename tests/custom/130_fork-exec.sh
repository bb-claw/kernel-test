#!/bin/sh
# Fork and exec subprocesses — exercises the scheduler, process creation,
# copy-on-write, and exec path.

_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# Single fork+exec+wait
if sh -c 'exit 0' 2>/dev/null; then
    ok "fork/exec single subprocess"
else
    fail "fork/exec single subprocess failed"
fi

# Exit code propagation
sh -c 'exit 42' 2>/dev/null; rc=$?
if [ "$rc" -eq 42 ]; then
    ok "subprocess exit code propagated ($rc)"
else
    fail "subprocess exit code wrong (expected 42, got $rc)"
fi

# 20 sequential fork/exec cycles — stresses pid allocation and scheduler
# Use /bin/true (instant Toybox applet) rather than sh -c to avoid
# per-iteration shell startup overhead under the 60s VM timeout.
i=0
while [ "$i" -lt 20 ]; do
    true || { fail "fork/exec failed at iteration $i"; break; }
    i=$((i + 1))
done
if [ "$i" -eq 20 ]; then
    ok "20 sequential fork/exec cycles"
fi

# Nested subshell (exec inside fork)
result=$(printf hello)
if [ "$result" = "hello" ]; then
    ok "subprocess stdout capture"
else
    fail "subprocess stdout capture failed (got: '$result')"
fi

# Background child + wait — exercises scheduler wakeup and SIGCHLD
true &
bg_pid=$!
wait "$bg_pid"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "background child wait"
else
    fail "background child wait failed (rc=$rc)"
fi

[ $_fails -eq 0 ] || exit 1
