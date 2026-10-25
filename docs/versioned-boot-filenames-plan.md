# versioned-boot-filenames — Design Plan

## Problem

`make install` derives the boot filename suffix from `{config}-{label}-{major.minor}-{arch}`
(e.g. `localconfig-stable-rc-7.2-x86_64`). The patch level and rc number are dropped, so
successive builds from the same series are indistinguishable in the GRUB boot menu:

```
kernel-test: localconfig-stable-rc-7.2-x86_64   ← rc1 or rc2 or rc3?
```

The user must boot and run `uname -r` to know which release they landed on.

## Root Cause

`BOOT_SUFFIX` is built from `MAJOR_MINOR` (`7.2`) rather than the full kernel version
(`7.2.13-rc2`). `MAJOR_MINOR` is derived from `kernel.release` via `grep -oE '^[0-9]+\.[0-9]+'`,
discarding SUBLEVEL (`13`) and EXTRAVERSION (`-rc2`).

## Solution

1. **Full version in filename** — call `read_kernel_makefile_version()` (already in `common.sh`)
   which sets `KMV_FULL` (e.g. `7.2.13-rc2` or `7.3.0-rc2`). Use it in `BOOT_SUFFIX`.

2. **`kt-` prefix** — prefix all new-style boot files with `kt-` so the GRUB script glob
   stays tight and can never match a distro kernel (distro kernels never start with `kt-`).

3. **Backward-compatible GRUB glob** — change the glob in `/etc/grub.d/06_kernel-test` from
   `vmlinuz-localconfig-*-x86_64` to `vmlinuz-*config*-x86_64`. This matches:
   - New style:  `vmlinuz-kt-localconfig-stable-rc-7.2.13-rc2-x86_64`
   - Old style:  `vmlinuz-localconfig-mainline-7.2-x86_64`, `vmlinuz-tinyconfig-*`
   - Distro kernels (`vmlinuz-6.12-x86_64`) do **not** contain "config" — not matched.

4. **All configs** — the glob change means tinyconfig installs also appear in GRUB with
   full version labels (tinyconfig was previously invisible due to the hardcoded localconfig glob).

## New BOOT_SUFFIX format

```
kt-{config}-{label}-{KMV_FULL}-{arch}
# e.g. kt-localconfig-stable-rc-7.2.13-rc2-x86_64
#      kt-tinyconfig-mainline-7.3.0-rc2-x86_64
```

## Files Changed

| File | Change |
|---|---|
| `lib/install.sh` | Add `read_kernel_makefile_version` call; redefine `BOOT_SUFFIX`; update GRUB glob |
| `tests/ci/test-install-versioned-names.sh` | New CI test covering N1–N4 |
| `tests/ci/coverage-map.md` | N1–N4 entries |
| `scripts/dev-test.sh` | Register N1–N4; bump `total_paths` |

## Backward Compatibility

- Old-style `/boot/vmlinuz-localconfig-*-x86_64` files remain untouched.
- Both old and new files appear in GRUB via the updated glob.
- Old mkinitcpio presets (`/etc/mkinitcpio.d/localconfig-*`) remain valid.
- `make install` with a new build produces a fresh versioned file; the old short-named file
  stays and is not overwritten.

## Test Cases (N1–N4)

| ID | What is verified |
|---|---|
| N1 | `BOOT_SUFFIX` starts with `kt-` for a stable-rc kernel |
| N2 | `BOOT_SUFFIX` includes SUBLEVEL + EXTRAVERSION (full version, not just major.minor) |
| N3 | GRUB glob `vmlinuz-*config*-x86_64` matches new-style `kt-` files and old-style files |
| N4 | GRUB glob does **not** match distro-style `vmlinuz-6.12-x86_64` |
