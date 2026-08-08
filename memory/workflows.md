# Workflows & Make Commands
## Variables

| Variable | Default | Override example |
|---|---|---|
| `KERNEL_TREE` | `../linux` | `KERNEL_TREE=~/git/linux-stable` |
| `DATA_REPO` | `~/git/kernel-test-data` | `DATA_REPO=~/git/other-data` (or override in `local.mk`) |
| `STABLE_KERNEL_TREE` | `~/git/linux-stable` | — |
| `STABLE_RELEASE` | _(none)_ | `STABLE_RELEASE=7.1` |
| `TAG` | _(none)_ | `TAG=v7.2-rc2` (used by `make checkout` only) |
| `ARCHS_ALL` | `x86_64 i386 arm64 riscv` | fixed constant; not user-settable; exported to scripts for filename parsing |
| `ARCHS` | `$(ARCHS_ALL)` | `ARCHS=x86_64` |
| `CONFIGS` | all 9 profiles | `CONFIGS=defconfig` |
| `TIMEOUT` | `360` | `TIMEOUT=600` |
| `BUILD_TIMEOUT` | `1800` | `BUILD_TIMEOUT=0` (no limit — use for localconfig) |
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
| `CANARY` | `0` | `CANARY=1` — inject `CONFIG_BOOT_CANARY=y`+`CONFIG_DEBUG_42=y`; requires prior `make canary-patch` |
| `FILES` | _(none)_ | `FILES=security/landlock/fs.o` — required by `make verify-patch`; space-separated `.o` files or dirs |
| `BASE` | _(none)_ | `BASE=v7.2-rc4` — git ref for "before" state in `make verify-patch` before/after mode |
| `COMPILER` | `both` | `COMPILER=gcc\|clang\|both` — compiler selection for `make verify-patch` |
| `VERIFY_ARCHS` | `$(ARCHS)` | Architectures for `make verify-patch`; defaults to `ARCHS` so `ARCHS=x86_64` works as a shorthand |
| `CLEAN` | `0` | `CLEAN=1` — force clean rebuild of each build dir in `make verify-patch` |
| `BOARD_CONFIG` | `vf2config` | Config profile for `make hw*` targets |
| `BOARD_ARCH` | `riscv` | Arch for `make hw*` targets |
| `BOARD_TTY` | `/dev/ttyUSB0` | USB-UART device for `make hw-test` / `make hw` |
| `BOARD_DTB` | `jh7110-starfive-visionfive-2-v1.2a` | DTB filename (no .dtb) built from kernel tree and copied to `tftp/vf2.dtb` by `make hw-deploy`; v1.3B users: `jh7110-starfive-visionfive-2-v1.3b` |
| `TFTP_DIR` | `$(CURDIR)/tftp` | Local TFTP root; gitignored; auto-created by `make hw-deploy` |
| `HW_TIMEOUT` | `120` | Serial capture timeout for board boot (U-Boot + TFTP + kernel + tests); separate from `TIMEOUT` (QEMU) |
| `HW_IFACE` | `eno1` | Ethernet interface for isolated test network (`make hw-bootstrap`) |
| `HW_HOST_IP` | `192.168.100.1` | Static IP on `HW_IFACE`; TFTP next-server in DHCP reply |
| `HW_DHCP_RANGE` | `192.168.100.100,192.168.100.200` | DHCP pool for the board |
| `HW_RELAY` | `/dev/vf2-relay` | Stable udev symlink to USB relay for `board_reset` |
| `HW_RELAY_VID`/`HW_RELAY_PID` | `1a86`/`7523` | USB VID:PID of relay (CH340 defaults); override in `local.mk` (e.g. CP210x: `10c4`/`ea60`) |

`KERNEL_TREE` and `DATA_REPO` are tilde-expanded and absolutified at Makefile parse time.
When `STABLE_RELEASE` is set, `KERNEL_TREE` is automatically overridden to `STABLE_KERNEL_TREE`.

## Common Workflows

### Full pipeline variants

```sh
make fetch                                            # auto-dispatches: mainline/stable/stable-rc by preset
make fetch-next                                       # linux-next only (kernel-test-next clone)
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux-stable  # pin specific version
make all NO_FETCH=1                                   # run after pin (all configs + archs)
make smoke                                            # kunitconfig + tinyconfig, preset auto-selected
make full                                             # 5 bootable configs, preset auto-selected
make ns-smoke                                         # kunitnsconfig + tinynsconfig (requires make bootstrap)
make ns-full                                          # 5 ns-variant configs (mirrors full)
make extended                                         # full then ns-full (10 configs); for staging automation
make local                                            # localconfig x86_64, no build timeout
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64  # single config/arch
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig    # fast iteration (no rebuild)
make hw-bootstrap [DRY_RUN=1]                         # install dnsmasq/networkd/udev for board testing (needs sudo)
make hw-deploy                                        # copy kernel+initramfs to TFTP_DIR (default: ./tftp/)
make hw-test BOARD_TTY=/dev/ttyUSB0                  # capture serial; hardware equivalent of make test
make hw BOARD_TTY=/dev/ttyUSB0                        # build → hw-deploy → hw-test → report
make hw-full BOARD_TTY=/dev/ttyUSB0                   # build → test (QEMU) → hw-deploy → hw-test → report
```

`make fetch` dispatches: `LINUX_NEXT=1` → error; `STABLE_RC_BRANCH` set → branch reset; `STABLE_RELEASE` set → stable tag; else → mainline rc tag. Falls back to local tags on TLS errors. Update `STABLE_RC_BRANCH` in `presets/kernel-test-stable-rc.mk` when the series bumps.

### Regression diff / baseline

```sh
make diff                                             # auto-detect latest two same-label runs
make diff OLD=reports/mainline-...-rc1 NEW=reports/mainline-...-rc2
make baseline                                         # pin latest run; future runs auto-diff against it
```

`lib/diff.sh` compares per-test: `PASS→FAIL` = regression, `FAIL→PASS` = fix.

### Warning analysis

```sh
make warnings                                         # (re-)analyse warnings from existing build/ logs; writes to latest report dir
make warnings-baseline                                # pin latest run as warning baseline; future runs auto-diff against it
```

`lib/warnings.sh` runs automatically at the end of every `make all`/`make smoke`/`make full`/`make ns-smoke`. Writes per-combo `warnings-<config>-<arch>.txt`, `warnings-summary.txt` (counts + divergence vs x86_64 + new/fixed vs prev run), `warnings-diff-prev.txt`. Informational only.

### Config archive

```sh
make config-archive   # scan DATA_REPO/reports/, populate DATA_REPO/configs/archive_{passed,failed}/; auto-commits to data repo
```

### Consolidated cross-source index
`make consolidate-index` — merge per-source `archive_failed/index.txt` → `DATA_REPO/consolidation/index.{txt,html}`. Copy each machine's index to `DATA_REPO/consolidation/<label>/archive_failed/index.txt`.

### Replay an archived config

```sh
make replay CONFIG_FILE=configs/archive_passed/kconfig-tinyconfig-x86_64-v7.2-rc2-<sha256>.config
make replay CONFIG_FILE=configs/archive_failed/kconfig-randconfig-x86_64-v7.2-rc2-<sha256>-BUILD_FAIL.config
```

Parses `config` and `arch` from filename; copies archived `.config`, runs `olddefconfig`, continues normal pipeline.

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
Multi-pass tip: when `interaction` occurs, use the archived minimum-set config as the new
`CONFIG_FILE` and pin the most suspicious option as `PINNED_OPTS`; repeat until single confirmed.
The archived `-bisect-from-<sha>` suffix is always one level only (chaining is stripped).

### Kconfig subsystem sweep / boot canary

```sh
make kconfig-build SUBSYSTEM=pinctrl DRY_RUN=1     # list options; omit DRY_RUN=1 to build+boot each
make canary-patch && make all CANARY=1 CONFIGS=tinyconfig ARCHS=x86_64  # diagnose silent boots
```

### Patch verification / dmesg

```sh
make verify-patch FILES=security/landlock/fs.o [BASE=v7.2-rc4] [COMPILER=clang] [CLEAN=1]
make dmesg [DMESG_LABEL=stable]   # capture+analyse host kernel dmesg
```

`BASE=` before/after comparison via git worktree; Clang needs `clang`+`lld`+`llvm`.

**Rule:** Always use `make all NO_FETCH=1 ...` not chained targets.

### CI / linting
`make lint` — Tier 1 (bash -n, shellcheck bash+sh, context sizes, test-inventory, design doc); `make lint-context` — sizes only.
`make ci-test` — Tier 2 (tests/ci/test-*.sh, no kernel/QEMU). PR-title check CI-only. GitHub Actions: lint every push; ci-test on `lib/**`, `scripts/**`, `tests/ci/**`, Makefile changes.
**Operational:** `make clean` on tree switch; `GCC=gcc-15` for stable kernels pre-GCC 16; **Stable-rc is not a tag** — `v7.1.4-rc2` is the rolling `linux-7.1.y` branch tip; use `make fetch-stable-rc`.
