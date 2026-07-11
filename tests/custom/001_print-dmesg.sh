#!/bin/sh
# prints a dmesg

_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }
info() { printf 'info: %s\n' "$*"; }

info ">>> dmesg >>>"
dmesg
info "<<< dmesg <<<"

[ $_fails -eq 0 ] || exit 1
