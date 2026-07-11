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
    data=$(head -c 1 /dev/null 2>/dev/null)
    if [ -z "$data" ]; then
        ok "/dev/null: read returns empty"
    else
        fail "/dev/null: read not empty"
    fi
else
    fail "/dev/null missing"
fi

# /dev/zero — zero-byte source
if [ -e /dev/zero ]; then
    byte=$(head -c 1 /dev/zero 2>/dev/null | wc -c)
    if [ "$byte" = "1" ]; then
        ok "/dev/zero: read 1 byte"
    else
        fail "/dev/zero: could not read"
    fi
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
    byte=$(head -c 1 /dev/urandom 2>/dev/null | wc -c)
    if [ "$byte" = "1" ]; then
        ok "/dev/urandom readable"
    else
        fail "/dev/urandom: read failed"
    fi
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
