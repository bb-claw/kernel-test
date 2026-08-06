/*
 * arena-test: arena allocator extended with kernel-facing memory verification.
 *
 * Based on tests/programs/arena.c (bump allocator with linked blocks).
 * Extended for cross-arch testing: alignment (sizeof(void*)), page size
 * (getpagesize()), block overflow, and a 32 MiB write stress.
 *
 * Output: key=value lines parsed by 410_arena-memory.sh.
 * Exit: 0 = all tests passed, 1 = any test failed.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

/* ─── Arena allocator ─────────────────────────────────────────────────────── */

typedef struct ArenaBlock {
	struct ArenaBlock *next;
	unsigned char    *base;
	size_t            size;
	size_t            used;
} ArenaBlock;

typedef struct {
	ArenaBlock *head;
	ArenaBlock *first;
	size_t      block_size;
} Arena;

static ArenaBlock *block_new(size_t size)
{
	ArenaBlock *b = malloc(sizeof(ArenaBlock));
	if (!b) return NULL;
	b->base = malloc(size);
	if (!b->base) { free(b); return NULL; }
	b->size = size;
	b->used = 0;
	b->next = NULL;
	return b;
}

static Arena arena_create(size_t size)
{
	Arena a;
	a.block_size = size;
	a.head = a.first = block_new(size);
	return a;
}

static void arena_destroy(Arena *a)
{
	ArenaBlock *b = a->first;
	while (b) {
		ArenaBlock *next = b->next;
		free(b->base);
		free(b);
		b = next;
	}
	a->head = a->first = NULL;
}

static void *arena_alloc(Arena *a, size_t n)
{
	/* Align to sizeof(void*): 8 bytes on 64-bit arches, 4 bytes on i386. */
	size_t align   = sizeof(void *);
	size_t aligned = (n + align - 1) & ~(align - 1);

	if (a->head->used + aligned > a->head->size) {
		size_t sz = aligned > a->block_size ? aligned : a->block_size;
		ArenaBlock *b = block_new(sz);
		if (!b) return NULL;
		a->head->next = b;
		a->head = b;
	}
	void *ptr = a->head->base + a->head->used;
	a->head->used += aligned;
	return ptr;
}

static void arena_reset(Arena *a)
{
	for (ArenaBlock *b = a->first; b; b = b->next)
		b->used = 0;
	a->head = a->first;
}

static int block_count(const Arena *a)
{
	int n = 0;
	for (const ArenaBlock *b = a->first; b; b = b->next) n++;
	return n;
}

static size_t total_used(const Arena *a)
{
	size_t n = 0;
	for (const ArenaBlock *b = a->first; b; b = b->next) n += b->used;
	return n;
}

/* ─── Test: allocator correctness ────────────────────────────────────────── */

static int test_correctness(void)
{
	/*
	 * block_size=64: two small allocs (each aligned to sizeof(void*)) fit in
	 * the first block; a 64-byte alloc overflows to a second block.
	 * Using block_size=1 would conflict with alignment padding.
	 */
	Arena a = arena_create(64);
	if (!a.first) return 0;

	void *p1 = arena_alloc(&a, 1);  /* aligned to 8 → 8 bytes in block 1  */
	void *p2 = arena_alloc(&a, 7);  /* aligned to 8 → 8 bytes, total 16   */
	void *p3 = arena_alloc(&a, 64); /* 64 bytes needed, 48 left → overflow */
	int blocks = block_count(&a);   /* expect: 2 blocks                    */

	arena_reset(&a);
	size_t used = total_used(&a);   /* expect: 0                           */

	/* After reset, alloc reuses existing blocks — no new malloc */
	void *p4 = arena_alloc(&a, 1);
	int blocks_after = block_count(&a); /* expect: same block count        */

	arena_destroy(&a);

	return (p1 && p2 && p3 && p4) &&
	       (p1 != p2) &&
	       (blocks == 2) &&
	       (used == 0) &&
	       (blocks_after == blocks);
}

/* ─── Test: pointer alignment ─────────────────────────────────────────────── */

static int test_alignment(int *align_bytes_out)
{
	size_t align = sizeof(void *);
	*align_bytes_out = (int)align;

	Arena a = arena_create(4096);
	if (!a.first) return 0;

	static const size_t odd[] = {1, 3, 5, 7, 9, 15, 17, 31, 33, 63, 65};
	int ok = 1;
	for (size_t i = 0; i < sizeof(odd)/sizeof(odd[0]); i++) {
		void *p = arena_alloc(&a, odd[i]);
		if (!p || ((uintptr_t)p % align) != 0) { ok = 0; break; }
	}
	arena_destroy(&a);
	return ok;
}

/* ─── Test: page size and block overflow at page boundary ─────────────────── */

static int test_page_size(int *page_size_out)
{
	int ps = (int)getpagesize();
	*page_size_out = ps;

	/* Arena with exactly one page per block: filling one block must cause overflow */
	Arena a = arena_create((size_t)ps);
	if (!a.first) return 0;

	/* Fill the first page block exactly */
	arena_alloc(&a, (size_t)ps);
	/* Next alloc must land in a new block */
	void *p2 = arena_alloc(&a, 1);
	int blocks = block_count(&a);
	arena_destroy(&a);

	return (p2 != NULL) && (blocks >= 2) && (ps >= 4096);
}

/* ─── Test: 32 MiB write stress ──────────────────────────────────────────── */

static int test_stress(int *blocks_out)
{
	const size_t MB        = 1024 * 1024;
	const size_t stress_mb = 32;
	const size_t blk_size  = 65536;   /* 64 KiB per arena block */
	const size_t alloc_sz  = 4096;    /* alloc in 4 KiB chunks  */
	const size_t iters     = (stress_mb * MB) / alloc_sz;

	Arena a = arena_create(blk_size);
	if (!a.first) return 0;

	for (size_t i = 0; i < iters; i++) {
		unsigned char *p = arena_alloc(&a, alloc_sz);
		if (!p) { arena_destroy(&a); return 0; }
		/* Touch first and last byte of every chunk to verify writability */
		p[0]           = (unsigned char)(i & 0xff);
		p[alloc_sz-1]  = (unsigned char)((i >> 8) & 0xff);
	}

	*blocks_out = block_count(&a);
	arena_reset(&a);
	int reset_ok = (total_used(&a) == 0);
	arena_destroy(&a);
	return reset_ok;
}

/* ─── main ───────────────────────────────────────────────────────────────── */

int main(void)
{
	int ok = 1;

	/* correctness */
	int corr = test_correctness();
	printf("alloc_ok=%d\n", corr);
	printf("reset_ok=%d\n", corr);
	ok &= corr;

	/* alignment */
	int align_bytes = 0, align_ok = test_alignment(&align_bytes);
	printf("align_ok=%d\n", align_ok);
	printf("align_bytes=%d\n", align_bytes);
	ok &= align_ok;

	/* page size */
	int page_size = 0, page_ok = test_page_size(&page_size);
	printf("page_size=%d\n", page_size);
	printf("page_ok=%d\n", page_ok);
	ok &= page_ok;

	/* stress */
	int stress_blocks = 0, stress_ok = test_stress(&stress_blocks);
	printf("stress_mb=32\n");
	printf("stress_ok=%d\n", stress_ok);
	printf("stress_blocks=%d\n", stress_blocks);
	ok &= stress_ok;

	printf("overall=%s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
