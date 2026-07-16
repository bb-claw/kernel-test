# fix/build-sha256-kernel-version — Plan

Branch: `fix/build-sha256-kernel-version`
Start date: 2026-07-16

---

## Problems

### 1. CONFIG_SHA256 MISMATCH in kunitrandconfig i386

`build.sh` stores `CONFIG_SHA256` at line 207 — after all config steps, but **before**
`make bzImage` runs.  The kernel build's `syncconfig` step can modify `.config` during
the build to resolve residual dependency inconsistencies.  For `kunitrandconfig i386`
(many random `CONFIG_*KUNIT*=y` options with complex cross-arch deps), `syncconfig`
changes enough options that the file differs from the pre-build snapshot.

`report.sh` re-reads the file post-build and computes a different hash → **MISMATCH**
→ `OVERALL=FAIL`, even though the build and boot were clean.

x86_64 is not affected because the full option set is available; i386 has more options
dropped by `syncconfig`, producing a visible diff.

### 2. Kernel version shown as commit SHA for untagged trees

`report.sh` resolves `KERNEL_VERSION` in this order:

```
1. read build/.kernel-version
2. git describe --exact-match HEAD   (fails for untagged commits)
3. git rev-parse --short HEAD        (→ raw SHA, e.g. 01c8c5ba0)
```

`read_kernel_makefile_version` (in `common.sh`) is never tried, even though it always
produces the authoritative human-readable version (`v7.1.4-rc1` for stable-rc).

Affected cases:
- `NO_FETCH=1` with a shallow `linux-stable-rc` clone (no tags → git describe fails)
- `build/.kernel-version` manually set to a SHA by the user
- `build/.kernel-version` missing entirely on a fresh clone

Result: report dir named `stable-rc-01c8c5ba0-…-01c8c5ba0/`, subject line says
`Linux 01c8c5ba0 boot test`, `VERSION_SHORT` regex fails → SHA used as-is in all
report metadata.

---

## Fixes

### Fix 1: Recompute CONFIG_SHA256 after the build

Keep the pre-build INFO log (useful for confirming what was configured), but recompute
the SHA256 just before each `printf STATUS=…` write so the stored value always matches
the file the kernel build actually produced.

Changes in `lib/build.sh`:

- **PASS path** (currently line 231): add `CONFIG_SHA256=$(sha256sum …)` before the
  `printf`.
- **FAIL path** (currently line 226): same — `syncconfig` may have already run before
  the build failed.
- **TIMEOUT path** (currently line 222): same — partial build may have triggered
  `syncconfig`.

The `CONFIG_SHA256` variable initialised at line 207 becomes the pre-build log value
only; the three write sites each recompute it from the actual file on disk.

### Fix 2: Prefer `read_kernel_makefile_version` over SHA fallback

Change the version-resolution block in `lib/report.sh` so that `read_kernel_makefile_version`
is tried before falling back to the git short SHA:

```
1. read build/.kernel-version  (valid if it starts with 'v' + digit)
2. read_kernel_makefile_version  (authoritative; reads VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION)
3. git describe --exact-match HEAD
4. git rev-parse --short HEAD  (last resort; still a SHA, but only if Makefile unreadable)
```

`read_kernel_makefile_version` is already defined in `common.sh` which `report.sh`
sources.  For `linux-stable-rc` at commit `01c8c5ba0` it returns `v7.1.4-rc1`
(SUBLEVEL=4 > 0 → `v7.1.4-rc1` path).

The same resolution order should also apply in `lib/build.sh`'s header INFO line for
consistency, though it is cosmetic only.

---

## Files Changed

| File | Change |
|---|---|
| `lib/build.sh` | Recompute `CONFIG_SHA256` at PASS/FAIL/TIMEOUT write points |
| `lib/report.sh` | Insert `read_kernel_makefile_version` before SHA fallback in version block |

No changes to: test scripts, initramfs, VM boot, report format.

`kunitrandconfig` is already in `BUILD_ONLY_CONFIGS` in the Makefile; this branch also
updates the Makefile help text and `CLAUDE.md` to document it as build-only (the code
was correct, the docs were not).

---

## Testing

```sh
# Fix 1: confirm no MISMATCH after build
make all NO_FETCH=1 CONFIGS=kunitrandconfig ARCHS=i386

# Fix 2: confirm version shown correctly for untagged stable-rc tree
# (with build/.kernel-version set to a SHA or deleted)
rm build/.kernel-version
make all NO_FETCH=1 KERNEL_TREE=~/git/linux-stable-rc LABEL=stable-rc GCC=gcc-15 \
    CONFIGS=tinyconfig ARCHS=x86_64
# → report dir must be stable-rc-7.1-…-v7.1.4-rc1/, not stable-rc-01c8c5ba0-…
```

---

## Scope

This fix applies to `kernel-test` (main), `kernel-test-stable`, and
`kernel-test-stable-rc`.  Cherry-pick or sync `lib/build.sh` and `lib/report.sh`
after merging.

---

## Note: GPU buddy test failure

`gpu_test_buddy_alloc_exceeds_max_order` (`gpu_buddy_test.c:1379`) fails on
`kunitrandconfig i386` on both v7.1.3 and v7.1.4-rc1 → **pre-existing**, not a
stable-rc regression.  No action needed for this branch.
