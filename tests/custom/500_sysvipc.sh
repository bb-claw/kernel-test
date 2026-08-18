#!/bin/sh
# System V IPC: shared memory (shmget/shmat/shmdt/shmctl),
# semaphores (semget/semop/semctl), message queues (msgget/msgsnd/msgrcv/msgctl).
# Skips when CONFIG_SYSVIPC=n (tinyconfig, allnoconfig).
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

BIN=/usr/bin/syscall-tests
[ -x "$BIN" ] || { skip "syscall-tests binary absent (run: make bootstrap)"; exit 0; }

[ -d /proc/sysvipc ] || { skip "CONFIG_SYSVIPC not available (/proc/sysvipc absent)"; exit 0; }

for subcmd in sysvipc-shm sysvipc-sem sysvipc-msg; do
    "$BIN" "$subcmd" > /tmp/st-sysvipc-out.txt 2>/tmp/st-sysvipc-err.txt
    rc=$?
    cat /tmp/st-sysvipc-out.txt
    [ "$rc" -eq 0 ] || fail "syscall-tests $subcmd exited $rc"
done

[ $fails -eq 0 ] || exit 1
