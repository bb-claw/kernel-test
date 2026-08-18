#!/bin/sh
# eBPF socket filter: bpf(BPF_PROG_LOAD, SOCKET_FILTER) via bpf() syscall.
# Exercises BPF verifier and JIT/interpreter path.
# Skips when CONFIG_BPF_SYSCALL=n (tinyconfig, allnoconfig).
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

BIN=/usr/bin/syscall-tests
[ -x "$BIN" ] || { skip "syscall-tests binary absent (run: make bootstrap)"; exit 0; }

"$BIN" bpf > /tmp/st-bpf-out.txt 2>/tmp/st-bpf-err.txt
rc=$?
cat /tmp/st-bpf-out.txt
[ "$rc" -eq 0 ] || fail "syscall-tests bpf exited $rc"

[ $fails -eq 0 ] || exit 1
