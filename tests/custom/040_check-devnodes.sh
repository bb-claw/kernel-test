#!/bin/sh
# Verify that essential device nodes are present and functional.

_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# /dev/null — discard device
if [ -e /dev/null ]; then
    # Write
    printf 'test' > /dev/null \
        && ok "/dev/null: write OK" || fail "/dev/null: write failed"
    # Read returns nothing
    data=$(dd if=/dev/null bs=1 count=1 2>/dev/null)
    [ -z "$data" ] \
        && ok "/dev/null: read returns empty" || fail "/dev/null: read not empty"
else
    fail "/dev/null missing"
fi

# /dev/zero — zero-byte source
if [ -e /dev/zero ]; then
    byte=$(dd if=/dev/zero bs=1 count=1 2>/dev/null | wc -c)
    [ "$byte" = "1" ] \
        && ok "/dev/zero: read 1 byte" || fail "/dev/zero: could not read"
else
    skip "/dev/zero not present"
fi

# /dev/console — must exist (kernel creates it in initramfs even without devtmpfs)
if [ -e /dev/console ]; then
    ok "/dev/console exists"
else
    fail "/dev/console missing"
fi

# /dev/urandom or /dev/random — entropy source
if [ -e /dev/urandom ]; then
    byte=$(dd if=/dev/urandom bs=1 count=1 2>/dev/null | wc -c)
    [ "$byte" = "1" ] \
        && ok "/dev/urandom readable" || fail "/dev/urandom: read failed"
elif [ -e /dev/random ]; then
    ok "/dev/random present (urandom absent)"
else
    skip "/dev/urandom and /dev/random not present"
fi

# /dev/kmsg — kernel message interface
if [ -e /dev/kmsg ]; then
    ok "/dev/kmsg exists"
else
    skip "/dev/kmsg not present"
fi

[ $_fails -eq 0 ] || exit 1
