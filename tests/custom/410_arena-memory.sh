#!/bin/sh
# Arena allocator memory verification: correctness, alignment, page size,
# write stress, and direct mmap — all with full write/read-back.
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
readback_ok=$(get readback_ok)
[ "$alloc_ok"    = "1" ] && ok "alloc: distinct non-NULL pointers, correct block count" \
                          || fail "alloc: correctness check failed"
[ "$readback_ok" = "1" ] && ok "alloc: write-then-read-back verified" \
                          || fail "alloc: memory write-read-back mismatch"

# ── Reset correctness ─────────────────────────────────────────────────────────

reset_ok=$(get reset_ok)
reset_cycles=$(get reset_cycles)
[ "$reset_ok" = "1" ] && ok "reset: arena_reset() correct ($reset_cycles cycles, no block leaks)" \
                        || fail "reset: arena_reset() failed"

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
[ "$page_ok" = "1" ] && ok "page: block overflow at page boundary (page_size=$page_size)" \
                       || fail "page: block overflow test failed"

# Page size must be >= 4096; arm64 kernels may use 4K, 16K, or 64K pages.
if [ "$page_size" -ge 4096 ] 2>/dev/null; then
    ok "page: page_size=$page_size is valid"
else
    fail "page: unexpected page_size=$page_size (expected >= 4096)"
fi

# ── 32 MiB write stress with full read-back ───────────────────────────────────

stress_ok=$(get stress_ok)
stress_readback_ok=$(get stress_readback_ok)
stress_blocks=$(get stress_blocks)
[ "$stress_ok" = "1" ] && ok "stress: 32 MiB allocated and reset ($stress_blocks blocks)" \
                         || fail "stress: 32 MiB allocation failed"
[ "$stress_readback_ok" = "1" ] && ok "stress: every byte verified on read-back" \
                                  || fail "stress: read-back mismatch — possible page aliasing"

# ── Direct mmap write + read-back ─────────────────────────────────────────────

mmap_ok=$(get mmap_ok)
mmap_pages=$(get mmap_pages)
[ "$mmap_ok" = "1" ] && ok "mmap: MAP_ANONYMOUS write+read-back passed ($mmap_pages pages)" \
                       || fail "mmap: MAP_ANONYMOUS verification failed"

[ $fails -eq 0 ] || exit 1
