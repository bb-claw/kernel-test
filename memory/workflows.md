# Workflows & Make Commands

## Variables

| Variable | Default | Override example |
|---|---|---|
| `KERNEL_TREE` | `../linux` | `KERNEL_TREE=~/git/linux-stable` |
| `STABLE_KERNEL_TREE` | `~/git/linux-stable` | — |
| `STABLE_RELEASE` | _(none)_ | `STABLE_RELEASE=7.1` |
| `TAG` | _(none)_ | `TAG=v7.2-rc2` (used by `make checkout` only) |
| `ARCHS` | `x86_64 i386` | `ARCHS=x86_64` |
| `CONFIGS` | all 8 profiles | `CONFIGS=defconfig` |
| `TIMEOUT` | `60` | `TIMEOUT=120` |
| `BUILD_TIMEOUT` | `1200` | `BUILD_TIMEOUT=0` (no limit — use for localconfig) |
| `NO_FETCH` | `0` | `NO_FETCH=1` |
| `NO_BUILD` | `0` | `NO_BUILD=1` |
| `V` | `0` | `V=1` |

`KERNEL_TREE` is tilde-expanded and absolutified at Makefile parse time.
When `STABLE_RELEASE` is set, `KERNEL_TREE` is automatically overridden to `STABLE_KERNEL_TREE`.

---

## Common Workflows

### Full pipeline — latest mainline rc

```sh
make KERNEL_TREE=~/git/linux-stable
```

### Full pipeline — specific rc version

```sh
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux-stable
make all NO_FETCH=1 KERNEL_TREE=~/git/linux-stable
```

### Full pipeline — latest stable release

```sh
make STABLE_RELEASE=7.1
```

### Full pipeline — specific stable version

```sh
make checkout TAG=v7.1.3 STABLE_RELEASE=7.1
make all NO_FETCH=1 STABLE_RELEASE=7.1
```

### Single config, single arch (quick smoke)

```sh
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS="x86_64 i386"
```

### Fast iteration on test scripts (skip kernel rebuild)

```sh
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS="x86_64 i386 arm64"
```

Skips the build step, repacks the initramfs (< 1 s), boots and tests.
Use when only test scripts changed — kernel artifacts reused from prior run.
arm64 uses TCG (no KVM on x86 host); requires `aarch64-linux-gnu-gcc` + `qemu-system-aarch64`.

### Regression diff between two rc runs

```sh
# Auto-detect latest two runs
make diff

# Compare specific runs
make diff OLD=reports/2026-07-12_v7.2-rc1 NEW=reports/2026-07-12_v7.2-rc2

# Pin current results as baseline; future make all runs also diff against it
make baseline
```

`lib/diff.sh` compares per-test name: `PASS→FAIL` = regression, `FAIL→PASS` = fix.
Auto-diff vs previous run and vs pinned baseline runs at the end of every `make all`.
Diff output goes to terminal and `diff-prev.txt` / `diff-baseline.txt` in the report dir.

### Verbose build output

```sh
make all NO_FETCH=1 V=1 KERNEL_TREE=~/git/linux-stable
```

### Check what is currently checked out

```sh
make info KERNEL_TREE=~/git/linux-stable
```

---

## Rule: Always Use `make all`, Not Chained Targets

**Wrong:** `make build initramfs test report` — stops at first failure, report never written.

**Correct:** `make all NO_FETCH=1 ...` — always writes report even when build or test fails.

---

## Fetch Strategy

Both modes: `git ls-remote` to discover tag (no objects), then `git fetch --depth=1 <tag>`.
If tag already local, fetch is skipped entirely.

- **Mainline rc:** latest `v*-rc*` tag from `KERNEL_TREE`
- **Stable:** latest `vX.Y.*` (non-rc) from `STABLE_KERNEL_TREE`; remote URL verified to contain `/stable/` or `linux-stable`

---

## Build Timeout

`BUILD_TIMEOUT` (default 1200 s) wraps only the `bzImage` build step via `timeout(1)`.
Exit 124 → `STATUS=TIMEOUT` in `build.status` (distinct from `STATUS=FAIL`).
Config step and fragment step are NOT wrapped — they are fast.
defconfig/kunitconfig x86_64 takes ~10–12 min on a 16-core machine.
