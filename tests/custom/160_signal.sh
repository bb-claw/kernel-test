#!/bin/sh
# Signal delivery: kill syscall, signal termination, process state.
# Exercises kernel do_send_sig, signal_wake_up, and per-thread signal tracking.
# Does not use 'trap' — Toybox sh 0.8.9 treats it as an external command
# (not a builtin) and fails with 'No such file or directory'.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# kill -0: signal 0 tests permission and process existence without sending a signal
if kill -0 $$ 2>/dev/null; then
    ok "kill -0 self (process existence check)"
else
    fail "kill -0 self failed"
fi

# SIGTERM (15) to background process — default action is terminate
sh -c 'sleep 5' &
bg_pid=$!
kill -15 "$bg_pid" 2>/dev/null
wait "$bg_pid"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "SIGTERM (15) terminates background process (rc=$rc)"
else
    fail "background process survived SIGTERM"
fi

# SIGKILL (9) is unblockable — kernel must enforce termination
sh -c 'sleep 5' &
bg_pid=$!
kill -9 "$bg_pid" 2>/dev/null
wait "$bg_pid"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "SIGKILL (9) terminates background process (rc=$rc)"
else
    fail "background process survived SIGKILL"
fi

# SIGUSR1 (10) to background process — user-defined signal, default action terminate
sh -c 'sleep 5' &
bg_pid=$!
kill -10 "$bg_pid" 2>/dev/null
wait "$bg_pid"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "SIGUSR1 (10) terminates background process (rc=$rc)"
else
    fail "background process survived SIGUSR1"
fi

# /proc/self/status signal mask fields — kernel tracks per-thread signal state
for field in SigBlk SigIgn SigCgt; do
    if grep -q "^${field}:" /proc/self/status 2>/dev/null; then
        ok "/proc/self/status: $field present"
    else
        skip "/proc/self/status: $field not available"
    fi
done

[ $fails -eq 0 ] || exit 1
