#!/bin/sh
# ARM64 mandatory feature detection — skip on non-arm64 arches.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

arch=$(uname -m)
[ "$arch" = "aarch64" ] || { skip "not arm64 (arch=$arch)"; exit 0; }

[ -r /proc/cpuinfo ] || { skip "/proc/cpuinfo not readable"; exit 0; }
grep -q '^Features' /proc/cpuinfo 2>/dev/null || { skip "no Features line in /proc/cpuinfo"; exit 0; }

features=$(grep '^Features' /proc/cpuinfo | head -1 | cut -d: -f2)
ok "Features line present"

# Use space-padding to match whole words without relying on grep -w.
# features starts with a space (from cut -d: -f2); append one more space at end.
fp=" $features "

# AArch64 FP — mandatory on ARMv8-A
printf '%s' "$fp" | grep -q ' fp ' \
    && ok "FP present" || fail "FP absent (ARMv8-A regression)"

# NEON (Advanced SIMD) — mandatory on ARMv8-A
printf '%s' "$fp" | grep -q ' asimd ' \
    && ok "NEON (asimd) present" || fail "NEON (asimd) absent (ARMv8-A regression)"

# LSE (Large System Extensions) — mandatory on ARMv8.1-A; present in QEMU virt
printf '%s' "$fp" | grep -q ' atomics ' \
    && ok "LSE (atomics) present" || fail "LSE (atomics) absent (ARMv8.1-A regression)"

# Optional extensions — report presence without failing on absence.
for opt in sve paca pacg mte; do
    if printf '%s' "$fp" | grep -q " $opt "; then
        ok "optional: $opt present"
    else
        skip "optional: $opt not present"
    fi
done

[ $fails -eq 0 ] || exit 1
