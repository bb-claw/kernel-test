#!/bin/sh
# timerfd + eventfd + signalfd correctness.
# These are core kernel IPC primitives; no config gate required.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

BIN=/usr/bin/syscall-tests
[ -x "$BIN" ] || { skip "syscall-tests binary absent (run: make bootstrap)"; exit 0; }

"$BIN" fds > /tmp/st-fds-out.txt 2>/tmp/st-fds-err.txt
rc=$?
cat /tmp/st-fds-out.txt
[ "$rc" -eq 0 ] || fail "syscall-tests fds exited $rc"

[ $fails -eq 0 ] || exit 1
