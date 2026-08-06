#!/bin/sh
# RISC-V ISA extension detection — skip on non-riscv arches.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

arch=$(uname -m)
[ "$arch" = "riscv64" ] || { skip "not riscv (arch=$arch)"; exit 0; }

[ -r /proc/cpuinfo ] || { skip "/proc/cpuinfo not readable"; exit 0; }
grep -q '^isa' /proc/cpuinfo 2>/dev/null || { skip "no isa line in /proc/cpuinfo"; exit 0; }

isa=$(grep '^isa' /proc/cpuinfo | head -1 | cut -d: -f2)
ok "ISA string:$isa"

# Strip multi-letter extensions (everything from first _), leaving rv64imafdcsu or similar.
base=$(printf '%s' "$isa" | sed 's/_[a-z].*//')

printf '%s' "$base" | grep -q '64' && ok "64-bit ISA" || fail "not rv64"

# Mandatory base extensions for any standard RISC-V Linux kernel build.
for ext in i m a f d c; do
    printf '%s' "$base" | grep -q "$ext" \
        && ok "extension $ext" || fail "extension $ext absent"
done

[ $fails -eq 0 ] || exit 1
