#!/bin/sh
# AF_UNIX socketpair send/recv correctness.
# Exercises CONFIG_UNIX; skips when AF_UNIX is not supported.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

BIN=/usr/bin/syscall-tests
[ -x "$BIN" ] || { skip "syscall-tests binary absent (run: make bootstrap)"; exit 0; }

"$BIN" unix > /tmp/st-unix-out.txt 2>/tmp/st-unix-err.txt
rc=$?
cat /tmp/st-unix-out.txt
[ "$rc" -eq 0 ] || fail "syscall-tests unix exited $rc"

[ $fails -eq 0 ] || exit 1
