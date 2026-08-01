# verify-patch design plan

## Goal

`make verify-patch` builds one or more kernel source files with GCC and
Clang across multiple architectures, with optional before/after comparison
against a base git commit.  The primary use case is verifying a patch in
`KERNEL_TREE` before submission to LKML — confirming the patch fixes the
reported errors without introducing new failures anywhere.

---

## Usage

```sh
# Build security/landlock/fs.o with GCC and Clang across all four arches
make verify-patch FILES=security/landlock/fs.o

# Before/after comparison: build at v7.2-rc4 (before) and HEAD (after)
make verify-patch FILES=security/landlock/fs.o BASE=v7.2-rc4

# Single compiler
make verify-patch FILES=security/landlock/fs.o COMPILER=clang

# Specific arches only
make verify-patch FILES=security/landlock/fs.o ARCHS="arm64 x86_64"

# Multiple files
make verify-patch FILES="security/landlock/fs.o security/landlock/net.o"

# Entire directory
make verify-patch FILES=security/landlock/

# Force clean rebuild
make verify-patch FILES=security/landlock/fs.o CLEAN=1

# Verbose — print full compiler command line
make verify-patch FILES=security/landlock/fs.o V=1
```

---

## Variables

| Variable        | Default              | Description                                      |
|-----------------|----------------------|--------------------------------------------------|
| `FILES`         | *(required)*         | Space-separated `.o` files, dirs, or subtrees    |
| `BASE`          | *(none)*             | Git ref for "before" state; enables before/after |
| `COMPILER`      | `both`               | `gcc`, `clang`, or `both`                        |
| `VERIFY_ARCHS`  | `arm64 x86_64 riscv i386` | Architectures to test (separate from `ARCHS`) |
| `CONFIG`        | `allmodconfig`       | Kernel config target                             |
| `CLEAN`         | `0`                  | Set to `1` to force clean rebuild per combo      |
| `V`             | `0`                  | Set to `1` for verbose compiler output           |

`VERIFY_ARCHS` is independent of the main pipeline's `ARCHS` so that
`make verify-patch` always tests all four arches by default without
affecting `make all` invocations.

---

## Before/after mode (BASE=)

When `BASE=<git-ref>` is supplied:

1. A temporary git worktree is created at `build/verify-patch/worktree-base`
   pointing to `BASE` — no stashing or branch switching needed.
2. Each `<arch>-<compiler>` combo builds twice:
   - **before**: FILES built from the base worktree
   - **after**: FILES built from current `KERNEL_TREE`
3. The result table shows before/after error counts and a verdict:
   `FIXED`, `REGRESSION`, `UNCHANGED-PASS`, or `UNCHANGED-FAIL`.
4. The worktree is removed on exit (even on error via trap).

---

## Build directories

```
build/verify-patch/
  <arch>-<compiler>/        ← "after" build (current KERNEL_TREE)
  <arch>-<compiler>-base/   ← "before" build (BASE worktree, only with BASE=)
  worktree-base/            ← temporary git worktree (cleaned up on exit)
  logs-<timestamp>/         ← per-combo build logs (stdout + stderr)
    <arch>-<compiler>-after.log
    <arch>-<compiler>-after.setup.log
    <arch>-<compiler>-before.log
    <arch>-<compiler>-before.setup.log
    summary.txt             ← copy of the terminal table
```

Build directories are **reused** across runs (incremental rebuild of changed
files only). Set `CLEAN=1` to wipe and regenerate per-combo.

---

## Compiler handling

| Arch    | GCC                                              | Clang           |
|---------|--------------------------------------------------|-----------------|
| x86_64  | `ARCH=x86_64` (no CROSS\_COMPILE)               | `LLVM=1`        |
| i386    | `ARCH=i386` (no CROSS\_COMPILE)                 | `ARCH=i386 LLVM=1` |
| arm64   | `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`   | `ARCH=arm64 LLVM=1` |
| riscv   | `ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu-`   | `ARCH=riscv LLVM=1` |

`LLVM=1` tells the kernel build system to use the full LLVM toolchain
(clang, lld, llvm-ar, llvm-nm) and sets `--target=<triple>` automatically
for cross-compilation.

allmodconfig is generated per arch+compiler combination because compiler
capabilities affect which Kconfig options are selectable (e.g. GCC plugins
are disabled under Clang, Clang-specific sanitizers differ).

---

## Output

**Terminal** — summary table printed at the end of every run:

```
── verify-patch ──────────────────────────────────────────────────
Files:   security/landlock/fs.o
Config:  allmodconfig
Base:    v7.2-rc4  →  HEAD (fix/landlock-uninit)

 Arch    Compiler  Before        After         Verdict
─────────────────────────────────────────────────────────
 arm64   gcc       3 errors      PASS          FIXED
 arm64   clang     PASS          PASS          UNCHANGED-PASS
 x86_64  gcc       3 errors      PASS          FIXED
 x86_64  clang     PASS          PASS          UNCHANGED-PASS
 riscv   gcc       0 errors      PASS          UNCHANGED-PASS
 riscv   clang     PASS          PASS          UNCHANGED-PASS
 i386    gcc       0 errors      PASS          UNCHANGED-PASS
 i386    clang     PASS          PASS          UNCHANGED-PASS

Overall: FIXED — 2 combos improved, 0 regressions
Logs:    build/verify-patch/logs-2026-08-01_14-30-22/
```

**Log files** — full compiler output written to `build/verify-patch/logs-<timestamp>/`
for attaching to LKML replies or archiving alongside the patch.

---

## Exit code

| Condition                            | Exit |
|--------------------------------------|------|
| All combos pass (no BASE)            | `0`  |
| All errors fixed, no regressions     | `0`  |
| Any combo still has errors           | `1`  |
| Any regression introduced            | `1`  |

Exit `1` makes the target usable in scripts that gate on success, e.g.:

```sh
make verify-patch FILES=security/landlock/fs.o BASE=v7.2-rc4 && \
    git format-patch -1 | git send-email --to=mic@digikod.net --stdin
```

---

## Relationship to raw kernel make commands

`make verify-patch` wraps the same kernel make invocations you can run
directly.  Both approaches are valid:

```sh
# Raw — quick single-combo check, full control
make -C ~/git/linux-dev O=/tmp/test ARCH=arm64 LLVM=1 \
     allmodconfig olddefconfig security/landlock/fs.o

# Wrapper — systematic multi-arch/compiler run with summary and logs
make verify-patch FILES=security/landlock/fs.o BASE=v7.2-rc4
```

Use the raw form for exploration; use the wrapper when you need evidence
for a patch email (the log files provide the exact compiler output to quote).
