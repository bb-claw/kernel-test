#!/bin/sh
# io_uring SQE/CQE round-trip: ring setup, NOP submission, completion read.
# Exercises CONFIG_IO_URING; skips on ENOSYS/EPERM.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

BIN=/usr/bin/syscall-tests
[ -x "$BIN" ] || { skip "syscall-tests binary absent (run: make bootstrap)"; exit 0; }

"$BIN" io_uring > /tmp/st-io_uring-out.txt 2>/tmp/st-io_uring-err.txt
rc=$?
cat /tmp/st-io_uring-out.txt
[ "$rc" -eq 0 ] || fail "syscall-tests io_uring exited $rc"

[ $fails -eq 0 ] || exit 1
