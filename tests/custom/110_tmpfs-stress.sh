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

# Verify multiple small files (inode allocation path).
# Fixed word list avoids $(( )) arithmetic expansion which loops forever in
# Toybox sh 0.8.9 (same bug as 130_fork-exec).
_inode_ok=1
for _i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do
    printf '%d\n' "$_i" > "/tmp/kernel-test-inode-$$-$_i" \
        || { fail "inode alloc failed at $_i"; _inode_ok=0; break; }
done
[ "$_inode_ok" -eq 1 ] && ok "tmpfs 20 small file allocations"
for _i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do
    rm -f "/tmp/kernel-test-inode-$$-$_i"
done

rm -f "$TESTFILE"
[ $_fails -eq 0 ] || exit 1
