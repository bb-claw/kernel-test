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
| `STABLE_RC_BRANCH` | _(from preset)_ | Branch name for `make fetch-stable-rc`; set in `presets/kernel-test-stable-rc.mk` as `linux-7.1.y`; update when series bumps |
| `SUBSYSTEM` | _(none)_ | `SUBSYSTEM=pinctrl` — required by `make kconfig-check/kconfig-build` |
| `DRIVER` | _(none)_ | `DRIVER=pinctrl-bm1880` — restrict kconfig-check/kconfig-build to one driver (`.c` suffix ok) |
| `DRY_RUN` | `0` | `DRY_RUN=1` — print kconfig-build option list without building |
| `GATE_CFGS` | _(none)_ | `GATE_CFGS=CONFIG_X,CONFIG_Y` — enable extra gate symbols for drivers inside nested `if` blocks |

`KERNEL_TREE` is tilde-expanded and absolutified at Makefile parse time.
When `STABLE_RELEASE` is set, `KERNEL_TREE` is automatically overridden to `STABLE_KERNEL_TREE`.

---

## Common Workflows

### Full pipeline variants

```sh
make fetch                                            # auto-dispatches: mainline/stable/stable-rc by preset
make fetch-next                                       # linux-next only (kernel-test-next clone)
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux-stable  # pin specific version
make all NO_FETCH=1                                   # run after pin (all configs + archs)
make smoke                                            # kunitconfig + tinyconfig, preset auto-selected
make full                                             # 5 bootable configs, preset auto-selected
make local                                            # localconfig x86_64, no build timeout
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64  # single config/arch
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig    # fast iteration (no rebuild)
```

`make fetch` auto-dispatches based on preset variables:
- `LINUX_NEXT=1` set → **error**: use `make fetch-next` (linux-next has no rc tags)
- `STABLE_RC_BRANCH` set → `lib/fetch-stable-rc.sh` (branch fetch + reset)
- `STABLE_RELEASE` set → `lib/fetch.sh` stable mode
- neither → `lib/fetch.sh` mainline rc mode

`make fetch-next` (`lib/fetch-next.sh`): fetches `origin/master` from `~/git/linux-next`;
requires `LINUX_NEXT=1` (auto-set by `presets/kernel-test-next.mk`).

`STABLE_RC_BRANCH` is set in `presets/kernel-test-stable-rc.mk`. Update it when
the stable series bumps (e.g. 7.1.y → 7.2.y). See `docs/stable-rc-workflow.md`.

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

### Config archive

```sh
make config-archive   # scan all reports/, populate configs/archive_passed/ + configs/archive_failed/
```
Prints `[config-archive] enriched N of M failed rows with detail` at the end.
Failed index detail sources: BUILD_FAIL → first `error:` line from build log; BUILD_TIMEOUT → last build line (`last:`); BOOT_FAIL-kernel-panic → first `Kernel panic` line; BOOT_FAIL-oops → first `Oops`/`BUG:` line; BOOT_FAIL-timeout/* → last dmesg line (`last:`); TEST_FAIL → `FAILED_TESTS=` (`failed:`); KUNIT_FAIL → first `not ok` KTAP line. Truncated to 120 chars; silent when report dir absent.

### Replay an archived config

```sh
make replay CONFIG_FILE=configs/archive_passed/kconfig-tinyconfig-x86_64-v7.2-rc2-<sha256>.config
make replay CONFIG_FILE=configs/archive_failed/kconfig-randconfig-x86_64-v7.2-rc2-<sha256>-BUILD_FAIL.config
```

Parses `config` and `arch` from filename; copies archived `.config`, runs `olddefconfig`,
then continues the normal pipeline (initramfs → test → report).

### Kconfig subsystem sweep (kconfig-build)

```sh
make kconfig-build SUBSYSTEM=pinctrl DRY_RUN=1              # list options without building
make kconfig-build SUBSYSTEM=pinctrl DRIVER=pinctrl-bm1880 ARCHS=arm64  # single driver
make kconfig-build SUBSYSTEM=pinctrl                         # all options × all archs
```
Per option: tinyconfig + `configs/randkconfigconfig.config` + `CONFIG_<OPT>=y` → build + boot.

### Capture and analyse host kernel dmesg

```sh
make dmesg                         # label: mainline (default)
make dmesg DMESG_LABEL=stable      # or: longterm / linux-next
```

`lib/dmesg.sh`; valid labels: `mainline stable longterm linux-next`.

---

## Rule: Always Use `make all`, Not Chained Targets

**Wrong:** `make build initramfs test report` — stops at first failure, report never written.

**Correct:** `make all NO_FETCH=1 ...` — always writes report even when build or test fails.

---

## Fetch Strategy

Tag-based modes: `git ls-remote` to discover tag (no objects), then `git fetch --depth=1 <tag>`.
If tag already local, fetch is skipped entirely.

- **Mainline rc:** latest `v*-rc*` tag from `KERNEL_TREE`
- **Stable:** latest `vX.Y.*` (non-rc) from `STABLE_KERNEL_TREE`; remote URL verified to contain `/stable/` or `linux-stable`
- **Stable-rc:** `git fetch origin <STABLE_RC_BRANCH>` + `git reset --hard FETCH_HEAD`; no tags
- **linux-next:** `git fetch origin master` + `git reset --hard FETCH_HEAD`; no tags; use `make fetch-next`

---

## Build Timeout

`BUILD_TIMEOUT` (default 1200 s) wraps only the `bzImage` build step via `timeout(1)`.
Exit 124 → `STATUS=TIMEOUT` in `build.status` (distinct from `STATUS=FAIL`).
Config step and fragment step are NOT wrapped — they are fast.
defconfig/kunitconfig/kunitrandconfig x86_64 takes ~10–12 min on a 16-core machine.
