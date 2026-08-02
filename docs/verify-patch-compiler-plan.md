# verify-patch compiler support — Plan

Branch: `feat/verify-patch-compiler`
Start date: 2026-08-02

---

## Situation

`make verify-patch` builds kernel object files with GCC across multiple
architectures to verify patch correctness. Clang builds (kernel `LLVM=1`) were
not supported, and several robustness gaps existed: MAKEFLAGS poisoning from the
parent make, stale worktree handling on re-runs, silent no-op for directory
targets, and detached HEAD display. `lib/bootstrap.sh` also did not install the
LLVM toolchain needed for Clang builds.

---

## Problems to Solve

1. **No Clang support** — `COMPILER=clang|both` was not implemented; `LLVM=1` kernel builds untested
2. **MAKEFLAGS poisoning** — parent make's `MAKEFLAGS`/`MAKELEVEL` leaked into kernel make invocations
3. **Stale worktree** — re-running with `BASE=` failed if the worktree directory already existed
4. **Directory targets** — `FILES=security/landlock/` silently skipped stale `.o` removal (`rm -f` on a dir is a no-op)
5. **Detached HEAD display** — `rev-parse --abbrev-ref HEAD` returns `"HEAD"` on detached HEAD; header showed `HEAD` instead of a useful ref
6. **Unsafe build_dir** — no guard against empty or relative `build_dir` before `rm -rf`
7. **No LLVM in bootstrap** — `clang`, `lld`, `llvm` not installed; `clang` does not pull in `llvm` on Arch or Debian

---

## Goals

1. `COMPILER=both` (default) builds with GCC and Clang across all four architectures
2. Re-runs with `BASE=` are idempotent — stale worktree cleaned up automatically
3. Directory targets correctly invalidate all `.o` files inside
4. Detached HEAD shows short SHA in header, not `"HEAD"`
5. `build_dir` guarded — script aborts on empty or relative path
6. `make bootstrap` installs full LLVM toolchain; sanity checks `clang` and `llvm-ar`
7. Patch quality and review workflow documented with pre-send checklist

---

## Scope

- `scripts/verify-patch.sh` — Clang/LLVM=1 support, MAKEFLAGS fix, worktree fix, dir stale removal, HEAD display, build_dir guard
- `lib/bootstrap.sh` — `clang lld llvm` in all four distro blocks; `clang`/`llvm-ar` sanity checks and REQUIRED entries
- `Makefile` — `CLEAN` variable export; bootstrap help text
- `docs/verify-patch-plan.md` — corrected impossible example rows
- `docs/patch-quality-workflow.md` — new: pre-send quality gate + reviewer workflow
- `memory/patch-workflow.md` — new: compact reference
- `CLAUDE.md`, `memory/project.md`, `memory/workflows.md` — documentation sync

No changes to: build pipeline (`lib/build.sh`), test scripts, config profiles.

---

## Non-goals

- Full boot test integration into verify-patch (covered by `make all`; verify-patch is build-only by design)
- Automatic `Tested-by` generation (future work)
- Patch fetch (`b4 am`) integration (future work)

---

## Design decisions

### clang does not pull in llvm on Arch or Debian

On both distros, `clang` depends on `llvm-libs` (runtime), not `llvm` (tools).
`llvm-ar`, `llvm-nm`, `llvm-strip` etc. live in the `llvm` package and must be
installed explicitly. All three packages (`clang lld llvm`) are therefore added
to every distro block.

### MAKEFLAGS/MAKELEVEL cleared on every kernel make call

The kernel build system reads `MAKEFLAGS` from the environment. When invoked as a
sub-make from `make verify-patch`, the parent's flags (e.g. `-j16`) are inherited
and conflict with the kernel's own job management. Prefixing every `make` call with
`MAKEFLAGS='' MAKELEVEL=''` isolates the kernel build completely.

### Directory stale removal uses find, not rm -f

`rm -f path/to/dir/` is silently a no-op on Linux (cannot remove a directory with
`rm -f`). For directory targets, `find "${build_dir}/${f}" -name '*.o' -delete`
correctly removes all cached object files, forcing a full recompile of changed files.

---

## Testing strategy

- **verify-patch before/after** — run with `BASE=v7.2-rc5` against known-broken and known-fixed branches in `~/git/linux-dev`; expect `FIXED` verdict
- **Directory target** — `FILES=security/landlock/` with `CLEAN=1`
- **Detached HEAD** — `BASE=` on a detached HEAD; expect short SHA in header
- **COMPILER=clang** — single-compiler run; expect only clang rows in output
- **Multiple branches** — 5 verification rounds across different fix and review branches

---

## Testing commands

```sh
# 1. Landlock fix — arm64 gcc, before/after
make verify-patch FILES=security/landlock/fs.o BASE=v7.2-rc5 \
    ARCHS=arm64 COMPILER=gcc
# Expected: arm64 gcc FIXED (3 errors → PASS)

# 2. Directory target with CLEAN=1
make verify-patch FILES=security/landlock/ BASE=v7.2-rc5 \
    ARCHS=arm64 COMPILER=gcc CLEAN=1
# Expected: FIXED

# 3. myri10ge — multi-arch, both compilers
make verify-patch \
    FILES=drivers/net/ethernet/myricom/myri10ge/myri10ge.o \
    BASE=v7.2-rc5 ARCHS="arm64 x86_64"
# Expected: arm64-gcc FIXED, others UNCHANGED-PASS

# 4. Clang only
make verify-patch FILES=security/landlock/fs.o BASE=v7.2-rc5 \
    ARCHS=arm64 COMPILER=clang
# Expected: arm64-clang UNCHANGED-PASS (landlock bug is GCC-only)
```
