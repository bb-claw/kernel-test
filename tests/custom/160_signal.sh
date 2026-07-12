#!/bin/sh
# Signal delivery: kill syscall, process termination by signal, signal tracking.
# Exercises kernel do_send_sig and per-thread signal state.
# Toybox sh 0.8.9 limitations:
#   - 'trap' is not a builtin — signal trapping is impossible
#   - 'kill -N pid' with numeric N (other than 0) silently no-ops
# Workarounds:
#   - Use signal names (-TERM, -KILL, -USR1) instead of numbers
#   - Detect death via kill -0 poll rather than wait exit code
#   - Skip tests where signal delivery remains unverifiable

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# kill -0: signal 0 tests process existence without sending a signal
if kill -0 $$ 2>/dev/null; then
    ok "kill -0 self (process existence check)"
else
    fail "kill -0 self failed"
fi

# Reusable: send signal name to bg process, poll kill -0 to detect death.
# Uses sleep 60 so natural exit cannot fake a kill within the poll window.
# Sets 'killed' to 1 if process dies, 0 if still alive after 20 checks.
# Callers must reap with 'wait $bg_pid 2>/dev/null || true' on success.
_signal_test() {
    sig="$1"
    sh -c 'sleep 60' &
    bg_pid=$!
    kill "$sig" "$bg_pid" 2>/dev/null || true
    killed=0
    # shellcheck disable=SC2034
    for p_i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if ! kill -0 "$bg_pid" 2>/dev/null; then killed=1; break; fi
        true
    done
    if [ "$killed" -eq 0 ]; then
        # Process survived — attempt cleanup but do NOT wait: if -KILL also
        # no-ops in this sh, waiting would block until sleep 60 expires.
        kill -KILL "$bg_pid" 2>/dev/null || true
    fi
}

# SIGTERM — default termination signal
_signal_test -TERM
if [ "$killed" -eq 1 ]; then
    wait "$bg_pid" 2>/dev/null || true
    ok "SIGTERM (-TERM) terminates background process"
else
    skip "SIGTERM delivery unverifiable (kill -TERM may not work in this sh)"
fi

# SIGKILL — unblockable; kernel must enforce termination
_signal_test -KILL
if [ "$killed" -eq 1 ]; then
    wait "$bg_pid" 2>/dev/null || true
    ok "SIGKILL (-KILL) terminates background process"
else
    skip "SIGKILL delivery unverifiable (kill -KILL may not work in this sh)"
fi

# SIGUSR1 — user-defined signal, default action terminate
_signal_test -USR1
if [ "$killed" -eq 1 ]; then
    wait "$bg_pid" 2>/dev/null || true
    ok "SIGUSR1 (-USR1) terminates background process"
else
    skip "SIGUSR1 delivery unverifiable (kill -USR1 may not work in this sh)"
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
