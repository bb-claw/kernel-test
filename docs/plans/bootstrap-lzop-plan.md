# bootstrap: add lzop — Plan

Branch: `fix/bootstrap-lzop`
Start date: 2026-07-18

---

## Situation

`randconfig` and other random kernel configs can select `CONFIG_KERNEL_LZO=y`
(LZO compression for the kernel image). Building with this option requires the
`lzop` host binary. If `lzop` is absent, `make bzImage` exits with code 127
("command not found"), recording a false `BUILD_FAIL` result instead of the real
compile-time failure (or success) that should be measured.

## Problem

`lzop` was missing from the `make bootstrap` package lists for all four supported
distros (pacman, apt, dnf, zypper), so a fresh environment built by `make bootstrap`
could not build kernels with LZO compression.

## Fix

Add `lzop` to the package list for each distro in `lib/bootstrap.sh`. The package
name is `lzop` on all four distros.

## Files Changed

| File | Change |
|---|---|
| `lib/bootstrap.sh` | Add `lzop` to pacman, apt, dnf, zypper package lists |
