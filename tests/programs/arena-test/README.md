# tests/programs/arena-test/

Arena allocator extended with kernel-facing memory verification.  Cross-compiled
for all four architectures; injected into the initramfs at `usr/bin/arena-test`.
Exercised by `tests/custom/410_arena-memory.sh`.

## What it tests

| Test | Key=value output | What it verifies |
|---|---|---|
| Allocation correctness | `alloc_ok` | Distinct non-NULL pointers; block overflow at capacity |
| Write / read-back | `readback_ok` | Known byte written to each pointer reads back correctly — catches page aliasing |
| Reset correctness | `reset_ok`, `reset_cycles` | `arena_reset()` zeroes usage; 3 cycles without block leaks |
| Pointer alignment | `align_ok`, `align_bytes` | Every pointer aligned to `sizeof(void*)`: 8 bytes on 64-bit arches, 4 bytes on i386 |
| Page size | `page_size`, `page_ok` | `getpagesize()` ≥ 4096; block overflow at page boundary works |
| 32 MiB write stress | `stress_ok`, `stress_readback_ok`, `stress_blocks` | Every byte written and read back — forces all pages to be faulted in |
| Direct `mmap` | `mmap_ok`, `mmap_pages` | `mmap(MAP_ANONYMOUS)` write+read-back across 8 pages — bypasses `malloc()`, exercises kernel VMA path directly |

## Output format

```
alloc_ok=1
readback_ok=1
reset_ok=1
reset_cycles=3
align_ok=1
align_bytes=8        # 4 on i386
page_size=4096       # 16384 or 65536 on arm64 depending on kernel config
page_ok=1
stress_mb=32
stress_ok=1
stress_readback_ok=1
stress_blocks=512
mmap_ok=1
mmap_pages=8
overall=PASS
```

## Architecture notes

- **i386**: `align_bytes=4` (32-bit pointer); everything else `align_bytes=8`
- **arm64**: `page_size` reflects the kernel's `CONFIG_ARM64_PAGE_SIZE` setting
  (4 KiB, 16 KiB, or 64 KiB) — the stress test and mmap test are page-size-aware
- **riscv64**: same as x86_64 for pointer size and page size

## Build

```sh
make -C tests/programs/arena-test/ all   # all 4 arches
make -C tests/programs/arena-test/ clean
```
