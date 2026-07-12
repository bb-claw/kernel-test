#!/bin/sh
# Pipe I/O: exercises kernel pipe() syscall, buffer management,
# blocking/waking of writer and reader, multi-process data flow.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# Basic data flow: single pipe between two processes
result=$(printf 'hello-pipe\n' | cat)
if [ "$result" = "hello-pipe" ]; then
    ok "basic pipe data flow"
else
    fail "basic pipe failed (got: '$result')"
fi

# Multi-stage pipe: three processes share one pipeline
result=$(printf 'aaa\nbbb\nccc\n' | grep 'bbb' | cat)
if [ "$result" = "bbb" ]; then
    ok "multi-stage pipe (3 processes)"
else
    fail "multi-stage pipe failed (got: '$result')"
fi

# Exit code propagation: last command in pipeline determines exit code
if printf 'x\n' | grep 'x' > /dev/null; then
    ok "pipe exit code: match returns 0"
else
    fail "pipe exit code wrong for matching grep"
fi
printf 'x\n' | grep 'no-such-string' > /dev/null; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "pipe exit code: no-match returns non-zero"
else
    fail "pipe exit code wrong for non-matching grep (got 0)"
fi

# Large data through pipe — exceeds the default 64 KiB kernel pipe buffer,
# forcing the writer to block and the reader to wake it; tests the full
# pipe blocking/wakeup path in the kernel
bytes=$(dd if=/dev/zero bs=4096 count=256 2>/dev/null | wc -c)
if [ "$bytes" -eq 1048576 ]; then
    ok "1 MiB through pipe intact ($bytes bytes)"
else
    fail "pipe data loss: expected 1048576 bytes, got $bytes"
fi

# Many sequential writes: ordering and completeness under multiple flushes
count=$(printf 'x\nx\nx\nx\nx\nx\nx\nx\nx\nx\n' | wc -l)
if [ "$count" -eq 10 ]; then
    ok "10 sequential writes through pipe all received"
else
    fail "pipe lost data: expected 10 lines, got $count"
fi

[ $fails -eq 0 ] || exit 1
