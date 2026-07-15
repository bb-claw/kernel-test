# rand500config kernel compression exclusion — Plan

Branch: `fix/rand500config-kernel-compression`
Start date: 2026-07-15

---

## Situation

`rand500config` randomly samples 500 `=y` options from a constrained randconfig pool.
The pool is constrained by `configs/randconfig.config` to exclude heavy subsystems and
sanitizers, but it did not exclude kernel compression format options.

---

## Problem

`CONFIG_KERNEL_LZO=y` was randomly sampled on an i386 rand500config run.
Building a bzImage with LZO compression requires the `lzop` host tool, which is not
installed. The build failed with exit 127 (`vmlinux.bin.lzo: command not found`).

The same failure can occur with `CONFIG_KERNEL_BZIP2` (needs `bzip2`),
`CONFIG_KERNEL_LZMA`/`XZ` (needs `xz`), `CONFIG_KERNEL_LZ4` (needs `lz4`),
and `CONFIG_KERNEL_ZSTD` (needs `zstd`). Only `gzip` is universally available.

---

## Fix

Add all non-gzip compression formats to `configs/randconfig.config` so they cannot
appear in the sampling pool. The kernel's Kconfig `choice` block for compression then
falls back to the default (`CONFIG_KERNEL_GZIP=y`).

---

## Scope

Files changed:
- `configs/randconfig.config` — add `CONFIG_KERNEL_{BZIP2,LZMA,XZ,LZO,LZ4,ZSTD}=n`

No changes to: build pipeline, VM tests, report, other config profiles.

---

## Why randconfig.config and not rand500config.config

Excluding in `randconfig.config` prevents these options from entering the sampling
pool at all, so they can never be sampled and appended to `.config`. Adding them
to `rand500config.config` (which is applied last) would also work via olddefconfig,
but the cleaner semantics is "don't put broken options in the pool."

The same fix also applies to the `randconfig` build-only profile, which is desirable.

---

## Testing

Run `make all NO_FETCH=1 CONFIGS=rand500config ARCHS=i386` several times and confirm
no `KERNEL_LZO`/`KERNEL_LZ4`/etc. appear in `build/rand500config-i386/rand-sampled.config`.
