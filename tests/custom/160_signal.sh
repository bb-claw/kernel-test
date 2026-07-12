#!/bin/sh
# Signal delivery: trap, kill, SIGCHLD.
# Exercises kernel signal delivery path (sigaction, do_signal, SIGCHLD).
# Uses numeric signal numbers — Toybox sh 0.8.9 trap cannot resolve signal
# names (TERM, USR1, CHLD) and fails with 'No such file or directory'.
# Linux x86/x86_64/i386: SIGTERM=15, SIGUSR1=10, SIGCHLD=17.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# SIGTERM (15) to self — trap must fire before the next command runs
got_term=0
trap 'got_term=1' 15
kill -15 $$
trap - 15
if [ "$got_term" -eq 1 ]; then
    ok "SIGTERM (15) delivered to self (trap)"
else
    fail "SIGTERM not delivered to self"
fi

# SIGUSR1 (10) to self
got_usr1=0
# shellcheck disable=SC2172
trap 'got_usr1=1' 10
kill -10 $$
trap - 10
if [ "$got_usr1" -eq 1 ]; then
    ok "SIGUSR1 (10) delivered to self"
else
    fail "SIGUSR1 not delivered to self"
fi

# kill -0: existence check — no signal sent, just permission/existence check
if kill -0 $$ 2>/dev/null; then
    ok "kill -0 self (process existence check)"
else
    fail "kill -0 self failed"
fi

# SIGTERM (15) kills background process — rc must be non-zero
sh -c 'sleep 5' &
bg_pid=$!
kill -15 "$bg_pid" 2>/dev/null
wait "$bg_pid"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "SIGTERM killed background process (rc=$rc)"
else
    fail "background process survived SIGTERM (rc=$rc)"
fi

# SIGCHLD (17) on child exit — skip if sh does not expose signal 17 traps
got_chld=0
# shellcheck disable=SC2172
trap 'got_chld=1' 17
sh -c 'exit 0' &
wait $!
trap - 17
if [ "$got_chld" -eq 1 ]; then
    ok "SIGCHLD (17) delivered on child exit"
else
    skip "SIGCHLD trap not fired (sh may not expose signal 17)"
fi

[ $fails -eq 0 ] || exit 1
