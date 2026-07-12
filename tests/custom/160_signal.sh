#!/bin/sh
# Signal delivery: trap, kill, SIGCHLD.
# Exercises kernel signal delivery path (sigaction, do_signal, SIGCHLD).

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# SIGTERM to self — trap must fire before the next command runs
got_term=0
trap 'got_term=1' TERM
kill -TERM $$
trap - TERM
if [ "$got_term" -eq 1 ]; then
    ok "SIGTERM delivered to self (trap)"
else
    fail "SIGTERM not delivered to self"
fi

# SIGUSR1 to self
got_usr1=0
trap 'got_usr1=1' USR1
kill -USR1 $$
trap - USR1
if [ "$got_usr1" -eq 1 ]; then
    ok "SIGUSR1 delivered to self"
else
    fail "SIGUSR1 not delivered to self"
fi

# kill -0: existence check — no signal sent, just permission/existence check
if kill -0 $$ 2>/dev/null; then
    ok "kill -0 self (process existence check)"
else
    fail "kill -0 self failed"
fi

# SIGTERM to background process — process must die (rc != 0)
sh -c 'sleep 5' &
bg_pid=$!
kill -TERM "$bg_pid" 2>/dev/null
wait "$bg_pid"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "SIGTERM killed background process (rc=$rc)"
else
    fail "background process survived SIGTERM (rc=$rc)"
fi

# SIGCHLD on child exit — Toybox sh may not expose CHLD traps; skip if not fired
got_chld=0
trap 'got_chld=1' CHLD
sh -c 'exit 0' &
wait $!
trap - CHLD
if [ "$got_chld" -eq 1 ]; then
    ok "SIGCHLD delivered on child exit"
else
    skip "SIGCHLD trap not fired (sh may not expose CHLD)"
fi

[ $fails -eq 0 ] || exit 1
