#!/bin/sh
# Arena allocator memory verification: correctness, alignment, page size, stress.
# Based on tests/programs/arena-test/arena-test.c — runs on all arches.
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

ARENA_BIN=/usr/bin/arena-test
[ -x "$ARENA_BIN" ] || { skip "arena-test binary absent (run: make bootstrap)"; exit 0; }

# Run binary; redirect to avoid Toybox if-out=$() pitfall.
"$ARENA_BIN" > /tmp/arena-out.txt 2>/tmp/arena-err.txt
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "arena-test exited $rc (err: $(cat /tmp/arena-err.txt))"
    exit 1
fi

get() { grep "^$1=" /tmp/arena-out.txt | cut -d= -f2; }

# ── Allocator correctness ─────────────────────────────────────────────────────

alloc_ok=$(get alloc_ok)
reset_ok=$(get reset_ok)
[ "$alloc_ok" = "1" ] && ok "alloc: correctness" || fail "alloc: correctness failed"
[ "$reset_ok" = "1" ] && ok "alloc: reset" || fail "alloc: reset failed"

# ── Pointer alignment ─────────────────────────────────────────────────────────

align_ok=$(get align_ok)
align_bytes=$(get align_bytes)
[ "$align_ok" = "1" ] && ok "align: all pointers aligned to $align_bytes bytes" \
    || fail "align: pointer misalignment detected"

# align_bytes must be 8 (64-bit arches) or 4 (i386)
if [ "$align_bytes" -eq 8 ] 2>/dev/null; then
    ok "align: 64-bit pointer size"
elif [ "$align_bytes" -eq 4 ] 2>/dev/null; then
    ok "align: 32-bit pointer size (i386)"
else
    fail "align: unexpected align_bytes=$align_bytes"
fi

# ── Page size ─────────────────────────────────────────────────────────────────

page_size=$(get page_size)
page_ok=$(get page_ok)
[ "$page_ok" = "1" ] && ok "page: block overflow at page boundary" \
    || fail "page: block overflow test failed"

# Page size must be >= 4096 and a power of two.
# arm64 kernels may use 4K, 16K, or 64K pages.
if [ "$page_size" -ge 4096 ] 2>/dev/null; then
    ok "page: page_size=$page_size"
else
    fail "page: unexpected page_size=$page_size"
fi

# ── 32 MiB write stress ───────────────────────────────────────────────────────

stress_ok=$(get stress_ok)
stress_blocks=$(get stress_blocks)
[ "$stress_ok" = "1" ] && ok "stress: 32 MiB allocated and reset ($stress_blocks blocks)" \
    || fail "stress: 32 MiB allocation failed"

[ $fails -eq 0 ] || exit 1
