#!/bin/sh
# Extended /proc/self: fd/, fdinfo/, limits, io.
# Tests VFS fd tracking, resource limit reporting, and task I/O accounting —
# three separate kernel subsystems not covered by 150_mmap.sh (/proc/self/maps).
# Skips when CONFIG_PROC_FS is disabled (tinyconfig, allnoconfig).

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -d /proc/self/fd ] || { skip "proc-self-extended: /proc/self/fd absent (procfs disabled)"; exit 0; }

# ── /proc/self/fd: stdin/stdout/stderr always open ───────────────────────────

for fd in 0 1 2; do
    if [ -e "/proc/self/fd/$fd" ]; then
        ok "/proc/self/fd/$fd exists"
    else
        fail "/proc/self/fd/$fd missing"
    fi
done

# fd count must be at least 3
count=$(ls /proc/self/fd 2>/dev/null | wc -l)
if [ "$count" -ge 3 ] 2>/dev/null; then
    ok "/proc/self/fd: $count descriptors open (>= 3)"
else
    fail "/proc/self/fd: only $count descriptors (expected >= 3)"
fi

# ── /proc/self/fdinfo/1: stdout metadata ─────────────────────────────────────

if [ -r /proc/self/fdinfo/1 ]; then
    if grep -q "^pos:" /proc/self/fdinfo/1 2>/dev/null; then
        ok "/proc/self/fdinfo/1: pos field present"
    else
        fail "/proc/self/fdinfo/1: pos field missing"
    fi
    if grep -q "^flags:" /proc/self/fdinfo/1 2>/dev/null; then
        ok "/proc/self/fdinfo/1: flags field present"
    else
        fail "/proc/self/fdinfo/1: flags field missing"
    fi
else
    fail "/proc/self/fdinfo/1: not readable"
fi

# ── /proc/self/limits: resource limit table ──────────────────────────────────

if [ -r /proc/self/limits ]; then
    if grep -q "Max open files" /proc/self/limits 2>/dev/null; then
        ok "/proc/self/limits: Max open files line present"
    else
        fail "/proc/self/limits: Max open files line missing"
    fi
    if grep -q "Max processes" /proc/self/limits 2>/dev/null; then
        ok "/proc/self/limits: Max processes line present"
    else
        fail "/proc/self/limits: Max processes line missing"
    fi
else
    fail "/proc/self/limits: not readable"
fi

# ── /proc/self/io: task I/O accounting ───────────────────────────────────────
# Requires CONFIG_TASK_IO_ACCOUNTING; skip this single check when absent.

if [ -r /proc/self/io ]; then
    if grep -q "^read_bytes:" /proc/self/io 2>/dev/null; then
        ok "/proc/self/io: read_bytes field present"
    else
        fail "/proc/self/io: read_bytes field missing"
    fi
    if grep -q "^write_bytes:" /proc/self/io 2>/dev/null; then
        ok "/proc/self/io: write_bytes field present"
    else
        fail "/proc/self/io: write_bytes field missing"
    fi
else
    skip "/proc/self/io: absent (CONFIG_TASK_IO_ACCOUNTING disabled)"
fi

[ $fails -eq 0 ] || exit 1
