#!/bin/sh
# Landlock enforcement: create ruleset, restrict path, verify open() is blocked.
# Exercises CONFIG_SECURITY_LANDLOCK; skips when landlock is unavailable.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

BIN=/usr/bin/syscall-tests
[ -x "$BIN" ] || { skip "syscall-tests binary absent (run: make bootstrap)"; exit 0; }

"$BIN" landlock > /tmp/st-landlock-out.txt 2>/tmp/st-landlock-err.txt
rc=$?
cat /tmp/st-landlock-out.txt
[ "$rc" -eq 0 ] || fail "syscall-tests landlock exited $rc"

[ $fails -eq 0 ] || exit 1
