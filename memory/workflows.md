# Workflows & Make Commands

## Variables

| Variable | Default | Override example |
|---|---|---|
| `KERNEL_TREE` | `../linux` | `KERNEL_TREE=~/git/linux-stable` |
| `STABLE_KERNEL_TREE` | `~/git/linux-stable` | — |
| `STABLE_RELEASE` | _(none)_ | `STABLE_RELEASE=7.1` |
| `TAG` | _(none)_ | `TAG=v7.2-rc2` (used by `make checkout` only) |
| `ARCHS` | `x86_64 i386 arm64` | `ARCHS=x86_64` |
| `CONFIGS` | all 9 profiles | `CONFIGS=defconfig` |
| `TIMEOUT` | `60` | `TIMEOUT=120` |
| `BUILD_TIMEOUT` | `1200` | `BUILD_TIMEOUT=0` (no limit — use for localconfig) |
| `NO_FETCH` | `0` | `NO_FETCH=1` |
| `NO_BUILD` | `0` | `NO_BUILD=1` |
| `V` | `0` | `V=1` |
| `DMESG_LABEL` | `mainline` | `DMESG_LABEL=stable` (used by `make dmesg` only) |
| `LABEL` | _(auto)_ | `LABEL=longterm` — report dir prefix; auto: STABLE_RELEASE→stable, linux-next tree→linux-next, vX.Y.Z→stable, else mainline |
| `local.mk` | _(absent)_ | Repo-specific overrides included before all `?=` defaults; stable repo sets `STABLE_RELEASE ?= 7.1`; stable-rc sets `KERNEL_TREE`, `LABEL`, `GCC`, `BUILD_TIMEOUT` |

`KERNEL_TREE` is tilde-expanded and absolutified at Makefile parse time.
When `STABLE_RELEASE` is set, `KERNEL_TREE` is automatically overridden to `STABLE_KERNEL_TREE`.

---

## Common Workflows

### Full pipeline variants

```sh
make KERNEL_TREE=~/git/linux-stable                   # latest mainline rc (with fetch)
make STABLE_RELEASE=7.1                               # latest stable vX.Y.*
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux-stable  # pin specific version
make all NO_FETCH=1                                   # run after pin (all configs + archs)
make smoke                                            # kunitconfig + tinyconfig, uses local.mk
make full                                             # 5 bootable configs, uses local.mk
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64  # single config/arch
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig    # fast iteration (no rebuild)
```

arm64 uses TCG (no KVM on x86 host); requires `aarch64-linux-gnu-gcc` + `qemu-system-aarch64`.
Default `ARCHS` includes arm64; pass `ARCHS="x86_64 i386"` to skip it.

### KUnit randomised coverage (kunitrandconfig)

Build-only (no VM boot). Rebuild required each run — `NO_BUILD=1` reuses previous sample,
defeating randomisation. Use `kunitconfig` for deterministic KUnit boot testing.

```sh
make all NO_FETCH=1 CONFIGS=kunitrandconfig ARCHS=x86_64  # new random sample each run
```

### Regression diff between two runs

```sh
# Auto-detect latest two runs of the same label
make diff

# Compare specific runs (cross-label also works)
make diff OLD=reports/mainline-7.2-2026-07-12_10-00-00-v7.2-rc1 NEW=reports/mainline-7.2-2026-07-12_11-00-00-v7.2-rc2

# Pin current results as baseline; future make all runs also diff against it
make baseline
```

`lib/diff.sh` compares per-test name: `PASS→FAIL` = regression, `FAIL→PASS` = fix.
Auto-detect restricts to same label as newest run (prevents spurious mainline/stable cross-diffs).
Auto-diff vs previous same-label run and vs pinned baseline runs at end of every `make all`.
Diff output goes to terminal and `diff-prev.txt` / `diff-baseline.txt` in the report dir.

### Migrate old report directories

```sh
bash scripts/migrate-reports.sh           # dry-run — shows old→new names
bash scripts/migrate-reports.sh --apply   # rename + update baseline symlink
```

Old format: `YYYY-MM-DD_HH-MM-SS_vX.Y-rcN` → New: `mainline-7.2-YYYY-MM-DD_HH-MM-SS-v7.2-rcN`
Label guessed from version: `-rcN` suffix → mainline; `vX.Y.Z` three-part → stable; else mainline.

### Capture and analyse host kernel dmesg

```sh
make dmesg                        # label: mainline (default)
make dmesg DMESG_LABEL=stable     # or: longterm / linux-next
make all NO_FETCH=1 V=1 KERNEL_TREE=~/git/linux-stable  # verbose build output
make info KERNEL_TREE=~/git/linux-stable                 # show checked-out version
```

Dmesg writes `dmesg/<name>.txt` and `dmesg/<name>-analysis.txt`; diffs warning/error
lines vs previous capture for same label; exits 1 on VERDICT=ERRORS.
Script: `lib/dmesg.sh`; valid labels: `mainline stable longterm linux-next`.

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
defconfig/kunitconfig/kunitrandconfig x86_64 takes ~10–12 min on a 16-core machine.
