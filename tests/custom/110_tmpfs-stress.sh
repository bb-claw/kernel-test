#!/bin/sh
# Stress tmpfs with a 1 MiB write/read/verify cycle.
# Exercises the page cache, slab allocator, and VFS write path more heavily
# than a single-line write.

_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if ! grep -q 'tmpfs' /proc/mounts 2>/dev/null; then
    skip "/tmp not mounted as tmpfs (CONFIG_TMPFS may be off)"
    exit 0
fi

TESTFILE=/tmp/kernel-test-stress-$$

# Write 1 MiB of zeros
if ! head -c 1048576 /dev/zero > "$TESTFILE" 2>/dev/null; then
    rm -f "$TESTFILE"
    fail "tmpfs 1MiB write failed"
    exit 1
fi
ok "tmpfs 1MiB write"

# Verify size
size=$(wc -c < "$TESTFILE" 2>/dev/null)
if [ "${size:-0}" -eq 1048576 ]; then
    ok "tmpfs file size correct (${size} bytes)"
else
    fail "tmpfs file size wrong (expected 1048576, got ${size:-?})"
fi

# Read back and discard
if cat "$TESTFILE" > /dev/null 2>/dev/null; then
    ok "tmpfs 1MiB read"
else
    fail "tmpfs 1MiB read failed"
fi

# Verify multiple small files (inode allocation path)
i=0
while [ $i -lt 20 ]; do
    printf '%d\n' "$i" > "/tmp/kernel-test-inode-$$-$i" || { fail "inode alloc failed at $i"; break; }
    i=$((i + 1))
done
[ $i -eq 20 ] && ok "tmpfs 20 small file allocations"
i=0
while [ $i -lt 20 ]; do rm -f "/tmp/kernel-test-inode-$$-$i"; i=$((i + 1)); done

rm -f "$TESTFILE"
[ $_fails -eq 0 ] || exit 1
