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
| `LABEL` | _(auto)_ | `LABEL=longterm` — auto: STABLE_RELEASE→stable, linux-next→linux-next, else mainline |
| `STABLE_RC_BRANCH` | _(from preset)_ | Branch for `make fetch-stable-rc`; set in `presets/kernel-test-stable-rc.mk` |
| `SUBSYSTEM` | _(none)_ | `SUBSYSTEM=pinctrl` — required by `make kconfig-check/kconfig-build` |
| `DRIVER` | _(none)_ | `DRIVER=pinctrl-bm1880` — restrict kconfig-check/kconfig-build to one driver |
| `DRY_RUN` | `0` | `DRY_RUN=1` — print bisect candidate list + time estimate, or kconfig-build list, without building |
| `GATE_CFGS` | _(none)_ | `GATE_CFGS=CONFIG_X,CONFIG_Y` — extra gate symbols for drivers inside nested `if` blocks |
| `PINNED_OPTS` | _(none)_ | `PINNED_OPTS=CONFIG_X,CONFIG_Y` — options injected into every bisect step but not baseline |

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

`make fetch` dispatches: `LINUX_NEXT=1` → error (use `make fetch-next`); `STABLE_RC_BRANCH` set →
branch fetch+reset; `STABLE_RELEASE` set → stable tag; neither → mainline rc tag.
Update `STABLE_RC_BRANCH` in `presets/kernel-test-stable-rc.mk` when the series bumps.

### Regression diff / baseline

```sh
make diff                                             # auto-detect latest two same-label runs
make diff OLD=reports/mainline-...-rc1 NEW=reports/mainline-...-rc2
make baseline                                         # pin latest run; future runs auto-diff against it
```

`lib/diff.sh` compares per-test: `PASS→FAIL` = regression, `FAIL→PASS` = fix.

### Config archive

```sh
make config-archive   # scan all reports/, populate configs/archive_passed/ + configs/archive_failed/
```

### Replay an archived config

```sh
make replay CONFIG_FILE=configs/archive_passed/kconfig-tinyconfig-x86_64-v7.2-rc2-<sha256>.config
make replay CONFIG_FILE=configs/archive_failed/kconfig-randconfig-x86_64-v7.2-rc2-<sha256>-BUILD_FAIL.config
```

Parses `config` and `arch` from filename; copies archived `.config`, runs `olddefconfig`,
then continues the normal pipeline (initramfs → test → report).

### Config bisect

```sh
make bisect CONFIG_FILE=configs/archive_failed/kconfig-rand500config-i386-<ver>-<sha>-BOOT_FAIL-timeout.config DRY_RUN=1
make bisect CONFIG_FILE=<path>
# Multi-pass: pin first suspect, bisect remaining candidates
make bisect CONFIG_FILE=<path> PINNED_OPTS=CONFIG_DEBUG_TEST_DRIVER_REMOVE=y
make bisect CONFIG_FILE=<path> PINNED_OPTS=CONFIG_X=y,CONFIG_Y=y
```

Binary-searches candidate options (archived − tinyconfig+bootability baseline) in ~8 cycles.
Result types: `single` (confirmed alone), `suspect` (needs co-required option → use PINNED_OPTS),
`interaction` (both halves pass → reports minimum known failing set).
Artifacts in `bisect/<timestamp>-<config>-<arch>-<sha256>/` (gitignored). Resumes on interruption.

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

---

## Rule: Always Use `make all`, Not Chained Targets

**Wrong:** `make build initramfs test report` — stops at first failure, report never written.

**Correct:** `make all NO_FETCH=1 ...` — always writes report even when build or test fails.

---

## Fetch Strategy

Tag-based: `git ls-remote` discovers tag (no objects), then `git fetch --depth=1 <tag>`.
If tag already local, fetch is skipped. `BUILD_TIMEOUT` (default 1200 s) wraps only the
`bzImage` step; exit 124 → `STATUS=TIMEOUT`. defconfig/kunitconfig x86_64 needs ~10–12 min.
