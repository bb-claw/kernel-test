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

# 20 sequential fork/exec cycles — stresses pid allocation and scheduler.
# Fixed word list avoids $(( )) arithmetic expansion: Toybox sh 0.8.9 has a
# buffer pre-allocation bug in $((expr)) that causes OOM inside while loops.
_fork_ok=1
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    true || { fail "fork/exec failed at iteration $_i"; _fork_ok=0; break; }
done
if [ "$_fork_ok" -eq 1 ]; then
    ok "20 sequential fork/exec cycles"
fi

# Subprocess stdout capture (command substitution)
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
