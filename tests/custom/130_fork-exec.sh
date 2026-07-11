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
[ "$rc" -eq 42 ] \
    && ok "subprocess exit code propagated ($rc)" \
    || fail "subprocess exit code wrong (expected 42, got $rc)"

# 20 sequential fork/exec cycles — stresses pid allocation and scheduler
i=0
while [ $i -lt 20 ]; do
    sh -c 'exit 0' 2>/dev/null || { fail "fork/exec failed at iteration $i"; break; }
    i=$((i + 1))
done
[ "$i" -eq 20 ] && ok "20 sequential fork/exec cycles"

# Nested subshell (exec inside fork)
result=$(sh -c 'printf hello')
[ "$result" = "hello" ] \
    && ok "subprocess stdout capture" \
    || fail "subprocess stdout capture failed (got: '$result')"

# Background child + wait — exercises scheduler wakeup and SIGCHLD
sh -c 'exit 0' &
wait $!; rc=$?
[ "$rc" -eq 0 ] \
    && ok "background child wait" \
    || fail "background child wait failed (rc=$rc)"

[ $_fails -eq 0 ] || exit 1
