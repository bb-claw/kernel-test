#!/bin/sh
# Verify tmpfs write/read works.
# Exercises the slab allocator and memory management path end-to-end.
_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if ! grep -q 'tmpfs' /proc/mounts 2>/dev/null; then
    skip "/tmp not mounted as tmpfs (CONFIG_TMPFS may be off)"
    exit 0
fi

TESTFILE=/tmp/kernel-test-$$
printf 'kernel-test-write\n' > "$TESTFILE"
val=$(cat "$TESTFILE")
rm -f "$TESTFILE"

if [ "$val" = "kernel-test-write" ]; then
    ok "tmpfs write/read"
else
    fail "tmpfs write/read mismatch (got: '$val')"
fi

[ $_fails -eq 0 ] || exit 1
