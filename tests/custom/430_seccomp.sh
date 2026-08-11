#!/bin/sh
# seccomp-filter enforcement: installs a BPF filter that blocks SYS_getpid.
# Verifies CONFIG_SECCOMP_FILTER; skips when seccomp is unavailable.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

BIN=/usr/bin/syscall-tests
[ -x "$BIN" ] || { skip "syscall-tests binary absent (run: make bootstrap)"; exit 0; }

"$BIN" seccomp > /tmp/st-seccomp-out.txt 2>/tmp/st-seccomp-err.txt
rc=$?
cat /tmp/st-seccomp-out.txt
[ "$rc" -eq 0 ] || fail "syscall-tests seccomp exited $rc"

[ $fails -eq 0 ] || exit 1
