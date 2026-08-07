/*
 * arena-test: arena allocator with kernel-facing memory verification.
 *
 * An "arena allocator" is a simple bump allocator: you allocate from a
 * block of memory by moving a pointer forward.  When a block fills up,
 * a new block is linked in.  You cannot free individual allocations —
 * instead you "reset" the whole arena (set all usage counters to zero)
 * and start over.  This pattern is much faster than malloc/free for
 * short-lived groups of allocations.
 *
 * Why use it for kernel testing?
 *   malloc() and mmap() both go through the kernel's virtual memory (VM)
 *   subsystem.  The tests below verify not just that memory is returned,
 *   but that the kernel actually mapped it correctly: we write a known
 *   pattern and read it back.  A kernel bug that maps the same physical
 *   page twice, or returns an unmapped address, will show up here.
 *
 * Output: one "key=value" line per result, parsed by 410_arena-memory.sh.
 * Exit:   0 if every test passed, 1 if any test failed.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>    /* uintptr_t — integer type wide enough to hold a pointer */
#include <unistd.h>    /* getpagesize()                                           */
#include <sys/mman.h>  /* mmap(), munmap(), MAP_ANONYMOUS, MAP_PRIVATE            */


/* ═══════════════════════════════════════════════════════════════════════════
 * Arena allocator
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Memory layout — a linked list of "blocks", each backed by a malloc buffer:
 *
 *   first ──► [ ArenaBlock │ base ────► [........used......│....free....] ]
 *                  │ next
 *                  ▼
 *             [ ArenaBlock │ base ────► [........used......│....free....] ]
 *                  │ next
 *                  ▼
 *                 NULL
 *
 * "head" always points to the block where the next allocation will land.
 */

typedef struct ArenaBlock {
    struct ArenaBlock *next;   /* link to the next block (NULL if last)   */
    unsigned char     *base;   /* raw byte buffer for this block          */
    size_t             size;   /* total capacity of the buffer (bytes)    */
    size_t             used;   /* bytes already handed out from base      */
} ArenaBlock;

typedef struct {
    ArenaBlock *head;       /* current block: new allocations go here    */
    ArenaBlock *first;      /* head of list: used to walk all blocks     */
    size_t      block_size; /* default size when a new block is created  */
} Arena;

/* Allocate one ArenaBlock struct plus its backing buffer of `size` bytes. */
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

/* Create an arena whose first block holds `block_size` bytes. */
static Arena arena_create(size_t block_size)
{
    Arena a;
    a.block_size = block_size;
    a.head = a.first = block_new(block_size);
    return a;
}

/* Free every block in the arena and reset all pointers to NULL. */
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

/*
 * Allocate `n` bytes from the arena.  Returns a non-NULL pointer on success
 * or NULL if malloc() fails when a new block is needed.
 *
 * Alignment: the returned pointer is always aligned to sizeof(void*) bytes.
 *   On 64-bit architectures (x86_64, arm64, riscv64) that is 8 bytes.
 *   On 32-bit i386 it is 4 bytes.
 *   Misaligned pointers cause hardware faults on strict-alignment CPUs
 *   (arm64, riscv) and silent performance penalties on x86.
 *
 *   Rounding formula: (n + align - 1) & ~(align - 1)
 *   Example (8-byte align): n=3  → (3+7) & ~7 = 10 & 0xFFFFF8 = 8
 *                           n=8  → (8+7) & ~7 = 15 & 0xFFFFF8 = 8
 *                           n=9  → (9+7) & ~7 = 16 & 0xFFFFF8 = 16
 *
 * Block reuse after reset: after arena_reset() all blocks still exist with
 * used=0.  Instead of always appending a new block on overflow, we first
 * walk forward through existing blocks.  This prevents memory leaks across
 * allocation cycles.
 */
static void *arena_alloc(Arena *a, size_t n)
{
    size_t align   = sizeof(void *);
    size_t aligned = (n + align - 1) & ~(align - 1);

    /*
     * Find a block with enough free space.
     * Walk forward through existing blocks before creating a new one.
     */
    while (a->head->used + aligned > a->head->size) {
        if (a->head->next) {
            a->head = a->head->next;   /* reuse block from a previous cycle */
        } else {
            size_t sz = aligned > a->block_size ? aligned : a->block_size;
            ArenaBlock *b = block_new(sz);
            if (!b) return NULL;
            a->head->next = b;
            a->head       = b;
        }
    }

    void *ptr = a->head->base + a->head->used;
    a->head->used += aligned;
    return ptr;
}

/*
 * Reset the arena: mark all blocks empty, restart from the first block.
 * Does NOT free memory — all blocks are kept for reuse by arena_alloc().
 */
static void arena_reset(Arena *a)
{
    for (ArenaBlock *b = a->first; b; b = b->next)
        b->used = 0;
    a->head = a->first;
}

/* Count how many blocks are in the linked list. */
static int block_count(const Arena *a)
{
    int n = 0;
    for (const ArenaBlock *b = a->first; b; b = b->next)
        n++;
    return n;
}

/* Sum all used bytes across every block. */
static size_t total_used(const Arena *a)
{
    size_t n = 0;
    for (const ArenaBlock *b = a->first; b; b = b->next)
        n += b->used;
    return n;
}


/* ═══════════════════════════════════════════════════════════════════════════
 * Test 1: Allocation correctness
 *
 * Verifies that arena_alloc() returns distinct non-NULL pointers and that
 * overflow into a second block works when a block fills up.
 *
 * Write-back check: writing a known byte to each pointer and reading it
 * back confirms the kernel mapped writable memory at those addresses.
 * A bug that returns overlapping or identical pages would cause one of
 * the writes to silently overwrite another, which the read-back catches.
 * ═══════════════════════════════════════════════════════════════════════════
 */
static int test_alloc(int *readback_ok_out)
{
    /*
     * Block size = 64 bytes.  Allocation sizes and alignment (64-bit shown):
     *   alloc(1)  → padded to  8 bytes  (block 1: 8/64 used)
     *   alloc(7)  → padded to  8 bytes  (block 1: 16/64 used)
     *   alloc(64) → needs 64, only 48 left in block 1 → overflow to block 2
     * Expected block count after these three allocations: 2.
     */
    Arena a = arena_create(64);
    if (!a.first) { *readback_ok_out = 0; return 0; }

    unsigned char *p1 = arena_alloc(&a, 1);
    unsigned char *p2 = arena_alloc(&a, 7);
    unsigned char *p3 = arena_alloc(&a, 64);

    int alloc_ok = p1 && p2 && p3           /* all pointers non-NULL       */
                   && (p1 != p2)            /* distinct addresses          */
                   && (p2 != p3)
                   && (block_count(&a) == 2); /* overflow created block 2  */

    /* Write a distinct byte to each pointer, then read it back. */
    if (p1) *p1 = 0xAA;
    if (p2) *p2 = 0xBB;
    if (p3) *p3 = 0xCC;

    *readback_ok_out = alloc_ok              /* skip deref if any ptr NULL */
                       && (*p1 == 0xAA)
                       && (*p2 == 0xBB)
                       && (*p3 == 0xCC);

    arena_destroy(&a);
    return alloc_ok;
}


/* ═══════════════════════════════════════════════════════════════════════════
 * Test 2: Reset correctness, verified across multiple cycles
 *
 * Verifies that arena_reset() empties all blocks and that subsequent
 * allocations reuse the existing blocks without leaking memory.
 *
 * Running 3 identical cycles proves that:
 *   (a) reset zeroes all usage counters, and
 *   (b) the block count never grows after the first cycle — the fixed-up
 *       arena_alloc() advances through existing blocks instead of creating
 *       new ones, which would be a memory leak.
 * ═══════════════════════════════════════════════════════════════════════════
 */
static int test_reset(int *cycles_out)
{
    const int CYCLES = 3;
    Arena a = arena_create(64);
    if (!a.first) { *cycles_out = 0; return 0; }

    int ok              = 1;
    int blocks_expected = -1;   /* set on the first allocation cycle */

    for (int i = 0; i < CYCLES; i++) {
        /* Same pattern as test_alloc: produces a 2-block layout */
        arena_alloc(&a, 1);
        arena_alloc(&a, 7);
        arena_alloc(&a, 64);   /* overflows on every cycle */

        if (i == 0)
            blocks_expected = block_count(&a);   /* expect 2 */

        arena_reset(&a);

        /* Every block must report zero bytes used after reset */
        if (total_used(&a) != 0) { ok = 0; break; }

        /* Block count must stay constant — growing means we leaked a block */
        if (block_count(&a) != blocks_expected) { ok = 0; break; }
    }

    *cycles_out = ok ? CYCLES : 0;
    arena_destroy(&a);
    return ok;
}


/* ═══════════════════════════════════════════════════════════════════════════
 * Test 3: Pointer alignment
 *
 * Verifies that every pointer returned by arena_alloc() is aligned to
 * sizeof(void*) bytes, regardless of the requested size.
 *
 * Why alignment matters for kernel testing:
 *   On strict-alignment CPUs (arm64, riscv64) an unaligned load or store
 *   raises a hardware alignment fault (SIGBUS).  On x86 it silently
 *   crosses cache lines, which is slow and can cause subtle bugs.
 *   Testing with odd request sizes (1, 3, 5, …) maximises the chance of
 *   catching an arithmetic error in the alignment rounding formula.
 * ═══════════════════════════════════════════════════════════════════════════
 */
static int test_alignment(int *align_bytes_out)
{
    size_t align = sizeof(void *);
    *align_bytes_out = (int)align;

    Arena a = arena_create(4096);   /* large enough for all allocations */
    if (!a.first) return 0;

    static const size_t odd_sizes[] = {1, 3, 5, 7, 9, 15, 17, 31, 33, 63, 65};
    int ok = 1;
    for (size_t i = 0; i < sizeof(odd_sizes) / sizeof(odd_sizes[0]); i++) {
        void *p = arena_alloc(&a, odd_sizes[i]);
        /* (uintptr_t)p converts the pointer to an integer for the modulo check */
        if (!p || (uintptr_t)p % align != 0) {
            ok = 0;
            break;
        }
    }

    arena_destroy(&a);
    return ok;
}


/* ═══════════════════════════════════════════════════════════════════════════
 * Test 4: Page size and block overflow at a page boundary
 *
 * Verifies that getpagesize() returns a sane value and that filling exactly
 * one page-sized block forces the arena to overflow into a second block.
 *
 * Why page size matters for kernel testing:
 *   The kernel manages virtual memory in fixed-size "pages".
 *   x86_64 and i386 always use 4096-byte pages.
 *   arm64 can be compiled for 4 KiB, 16 KiB, or 64 KiB pages (a Kconfig
 *   choice baked into the kernel binary).  The value returned by
 *   getpagesize() reflects the actual running kernel configuration, so a
 *   mismatch between the build config and the booted kernel shows up here.
 * ═══════════════════════════════════════════════════════════════════════════
 */
static int test_page_size(int *page_size_out)
{
    int ps = (int)getpagesize();
    *page_size_out = ps;

    if (ps < 4096) return 0;   /* sanity: a page must be at least 4 KiB */

    /*
     * One block = one page.  Allocating `ps` bytes fills block 1 exactly.
     * The next allocation (1 byte) must land in a new block 2.
     */
    Arena a = arena_create((size_t)ps);
    if (!a.first) return 0;

    arena_alloc(&a, (size_t)ps);   /* fills block 1 completely */
    void *p2 = arena_alloc(&a, 1); /* must overflow to block 2 */

    int ok = (p2 != NULL) && (block_count(&a) >= 2);
    arena_destroy(&a);
    return ok;
}


/* ═══════════════════════════════════════════════════════════════════════════
 * Test 5: 32 MiB write stress with full read-back
 *
 * Allocates 32 MiB in 4 KiB chunks, writes a distinct pattern to every
 * single byte, then reads back every byte and verifies it matches.
 *
 * Why write every byte (not just first and last):
 *   Linux uses demand paging: a page is only mapped to physical memory
 *   on the first access (page fault).  If we only touch two bytes per
 *   chunk, most pages are never faulted in and never verified.  Writing
 *   every byte forces every page to be faulted in, exercising the kernel's
 *   page-fault handler and physical memory allocator under real load.
 *   The read-back then catches page-aliasing bugs where two virtual
 *   addresses map to the same physical page.
 * ═══════════════════════════════════════════════════════════════════════════
 */
static int test_stress(int *blocks_out, int *readback_ok_out)
{
    const size_t MB        = 1024 * 1024;
    const size_t STRESS_MB = 32;
    const size_t BLK_SIZE  = 65536;                         /* 64 KiB arena blocks */
    const size_t CHUNK_SZ  = 4096;                          /* 4 KiB per alloc     */
    const size_t ITERS     = (STRESS_MB * MB) / CHUNK_SZ;  /* 8192 chunks total   */

    /*
     * Keep one pointer per chunk so we can walk them for the read-back.
     * 8192 pointers × 8 bytes = 64 KiB — negligible overhead.
     */
    unsigned char **ptrs = malloc(ITERS * sizeof(unsigned char *));
    if (!ptrs) { *blocks_out = 0; *readback_ok_out = 0; return 0; }

    Arena a = arena_create(BLK_SIZE);
    if (!a.first) {
        free(ptrs);
        *blocks_out = 0;
        *readback_ok_out = 0;
        return 0;
    }

    /* Phase 1: allocate and fill every byte with a chunk-index pattern */
    for (size_t i = 0; i < ITERS; i++) {
        ptrs[i] = arena_alloc(&a, CHUNK_SZ);
        if (!ptrs[i]) {
            arena_destroy(&a);
            free(ptrs);
            *blocks_out      = 0;
            *readback_ok_out = 0;
            return 0;
        }
        /*
         * Fill the whole chunk with (i & 0xff).  This writes every byte,
         * which forces every page to be faulted in by the kernel.
         */
        memset(ptrs[i], (unsigned char)(i & 0xff), CHUNK_SZ);
    }

    *blocks_out = block_count(&a);

    /* Phase 2: read back every byte and confirm the pattern is intact */
    int readback_ok = 1;
    for (size_t i = 0; i < ITERS && readback_ok; i++) {
        unsigned char  expected = (unsigned char)(i & 0xff);
        unsigned char *p        = ptrs[i];
        for (size_t j = 0; j < CHUNK_SZ; j++) {
            if (p[j] != expected) {
                readback_ok = 0;
                break;
            }
        }
    }
    *readback_ok_out = readback_ok;

    free(ptrs);

    arena_reset(&a);
    int reset_ok = (total_used(&a) == 0);
    arena_destroy(&a);
    return reset_ok;
}


/* ═══════════════════════════════════════════════════════════════════════════
 * Test 6: Direct mmap(MAP_ANONYMOUS) write + read-back
 *
 * Bypasses malloc() and asks the kernel directly for anonymous memory,
 * then writes and reads back every byte across 8 pages.
 *
 * Why this is different from the arena stress test:
 *   malloc() satisfies small requests via brk() (heap extension) and
 *   large ones via mmap().  By calling mmap() directly we guarantee the
 *   kernel's VMA (Virtual Memory Area) creation code path is exercised,
 *   regardless of how libc decides to serve the request.
 *
 * This test also verifies:
 *   - mmap() returns page-aligned memory (required by POSIX)
 *   - munmap() releases the mapping without faults
 *   - All mapped pages are read/write accessible
 *
 * Page-size awareness: we map num_pages × getpagesize() bytes so the test
 * is correct for arm64 with 4 KiB, 16 KiB, or 64 KiB pages.
 * ═══════════════════════════════════════════════════════════════════════════
 */
static int test_mmap(int *pages_out)
{
    int    page_size = (int)getpagesize();
    int    num_pages = 8;
    size_t map_size  = (size_t)num_pages * (size_t)page_size;

    unsigned char *mem = mmap(NULL, map_size,
                              PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS,
                              -1, 0);
    if (mem == MAP_FAILED) { *pages_out = 0; return 0; }

    /* Write page-index byte to every byte on every page */
    for (int i = 0; i < num_pages; i++) {
        unsigned char *page = mem + (size_t)i * (size_t)page_size;
        memset(page, (unsigned char)i, (size_t)page_size);
    }

    /* Read back every byte and verify the pattern */
    int ok = 1;
    for (int i = 0; i < num_pages && ok; i++) {
        unsigned char *page = mem + (size_t)i * (size_t)page_size;
        for (int j = 0; j < page_size && ok; j++) {
            if (page[j] != (unsigned char)i)
                ok = 0;
        }
    }

    *pages_out = ok ? num_pages : 0;
    munmap(mem, map_size);
    return ok;
}


/* ═══════════════════════════════════════════════════════════════════════════
 * main: run all tests, print key=value results
 * ═══════════════════════════════════════════════════════════════════════════
 */
int main(void)
{
    int all_ok = 1;

    /* Test 1: allocation correctness + write/read-back */
    int readback_ok = 0;
    int alloc_ok    = test_alloc(&readback_ok);
    printf("alloc_ok=%d\n",    alloc_ok);
    printf("readback_ok=%d\n", readback_ok);
    all_ok &= alloc_ok & readback_ok;

    /* Test 2: reset correctness across 3 cycles */
    int reset_cycles = 0;
    int reset_ok     = test_reset(&reset_cycles);
    printf("reset_ok=%d\n",     reset_ok);
    printf("reset_cycles=%d\n", reset_cycles);
    all_ok &= reset_ok;

    /* Test 3: pointer alignment */
    int align_bytes = 0;
    int align_ok    = test_alignment(&align_bytes);
    printf("align_ok=%d\n",    align_ok);
    printf("align_bytes=%d\n", align_bytes);
    all_ok &= align_ok;

    /* Test 4: page size and block overflow at page boundary */
    int page_size = 0;
    int page_ok   = test_page_size(&page_size);
    printf("page_size=%d\n", page_size);
    printf("page_ok=%d\n",   page_ok);
    all_ok &= page_ok;

    /* Test 5: 32 MiB write stress with full read-back */
    int stress_blocks = 0, stress_readback_ok = 0;
    int stress_ok     = test_stress(&stress_blocks, &stress_readback_ok);
    printf("stress_mb=32\n");
    printf("stress_ok=%d\n",          stress_ok);
    printf("stress_readback_ok=%d\n", stress_readback_ok);
    printf("stress_blocks=%d\n",      stress_blocks);
    all_ok &= stress_ok & stress_readback_ok;

    /* Test 6: direct mmap write + read-back */
    int mmap_pages = 0;
    int mmap_ok    = test_mmap(&mmap_pages);
    printf("mmap_ok=%d\n",    mmap_ok);
    printf("mmap_pages=%d\n", mmap_pages);
    all_ok &= mmap_ok;

    printf("overall=%s\n", all_ok ? "PASS" : "FAIL");
    return all_ok ? 0 : 1;
}
