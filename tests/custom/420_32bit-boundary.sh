#!/bin/sh
# 32-bit boundary: lseek64 >4 GiB + large anonymous mmap.
# Exercises VFS off_t handling and vm_area_struct address arithmetic.
# Most relevant on i386 (32-bit long), but correct on all arches.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

BIN=/usr/bin/syscall-tests
[ -x "$BIN" ] || { skip "syscall-tests binary absent (run: make bootstrap)"; exit 0; }

"$BIN" 32bit > /tmp/st-32bit-out.txt 2>/tmp/st-32bit-err.txt
rc=$?
cat /tmp/st-32bit-out.txt
[ "$rc" -eq 0 ] || fail "syscall-tests 32bit exited $rc"

[ $fails -eq 0 ] || exit 1
