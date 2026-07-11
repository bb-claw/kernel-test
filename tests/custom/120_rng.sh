#!/bin/sh
# Read from /dev/urandom — tests the kernel CRNG (random subsystem).
# Verifies the character device is present and returns the expected byte count.

_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

if [ ! -c /dev/urandom ]; then
    skip "/dev/urandom not present (CONFIG_RANDOM may be off)"
    exit 0
fi

# Read 512 bytes and verify the count
bytes=$(head -c 512 /dev/urandom 2>/dev/null | wc -c)
if [ "${bytes:-0}" -eq 512 ]; then
    ok "/dev/urandom read 512 bytes"
else
    fail "/dev/urandom: expected 512 bytes, got ${bytes:-0}"
fi

# Read 4096 bytes (one page) — exercises the CRNG output path more
bytes=$(head -c 4096 /dev/urandom 2>/dev/null | wc -c)
if [ "${bytes:-0}" -eq 4096 ]; then
    ok "/dev/urandom read 4096 bytes (one page)"
else
    fail "/dev/urandom: expected 4096 bytes, got ${bytes:-0}"
fi

# /dev/random — may block if entropy is low; just check it exists
if [ -c /dev/random ]; then
    ok "/dev/random present"
else
    skip "/dev/random not present"
fi

[ $_fails -eq 0 ] || exit 1
