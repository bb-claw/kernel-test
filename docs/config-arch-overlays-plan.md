# Design: Per-arch Config Overlays

Branch: `feat/config-arch-overlays`

## Problem

Every bootable config fragment (`configs/tinyconfig.config`,
`configs/allnoconfig.config`, …) currently embeds serial driver options for
all four architectures in one flat file:

```
CONFIG_SERIAL_8250=y           # x86/riscv
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_AMBA_PL011=y     # arm64
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_SERIAL_OF_PLATFORM=y    # riscv only
CONFIG_FPU=y                   # riscv only
```

`olddefconfig` silently drops options that have no Kconfig entry for the
target arch, so the result is correct — but the files are misleading and each
new arch requires touching every fragment.  Eight profiles × four arches =
growing maintenance surface.

## Solution

Split each fragment into a base (arch-neutral) + per-arch overlay:

```
configs/tinyconfig.config           ← arch-neutral options only
configs/tinyconfig-x86_64.config    ← 8250 serial
configs/tinyconfig-i386.config      ← 8250 serial
configs/tinyconfig-arm64.config     ← PL011 serial
configs/tinyconfig-riscv.config     ← 8250 + OF_PLATFORM + FPU
```

`build.sh` applies: **base → arch overlay → `olddefconfig`** (one pass).
If the arch overlay is absent the build continues without error (silently
skip).

## Decisions (from design review, 2026-07-25)

| Question | Decision |
|---|---|
| Base content | Arch-neutral only (PRINTK, TTY, INITRD, BINFMT, TMPFS, KERNEL_GZIP) |
| Arch suffix | Kernel arch names: `x86_64`, `i386`, `arm64`, `riscv` |
| File location | `configs/` flat directory |
| Missing overlay | Silently skip |
| Apply order | base → arch overlay → `olddefconfig` |
| Build-only profiles | Yes — overlays applied to ALL profiles |
| localconfig | Strip arm64/riscv sections from base; no overlay (x86_64-only) |
| BOOT_BASELINE_OPTS | Remove arch-specific entries only — serial/FPU now owned by overlays; 7 arch-neutral options remain |
| Overlay loader | `lib/build.sh` (alongside existing fragment logic) |
| x86_64 vs i386 | Separate files (allow future divergence) |
| Config archive regen | No — SHA256 archive is independent |
| Random config order | Arch overlay applied AFTER bootability fragment (last layer) |
| `kconfig-build` sweep | Yes — apply arch overlay in `lib/build-kconfig.sh` too |
| Shared base extraction | No — one base file per profile |
| CLAUDE.md | Add new row for arch overlay convention + update Conventions section |

## Overlay contents per arch

All nine profiles get the same arch overlay content (identical files per arch):

**`*-x86_64.config` and `*-i386.config`:**
```
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
```

**`*-arm64.config`:**
```
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
```

**`*-riscv.config`:**
```
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_OF_PLATFORM=y
CONFIG_FPU=y
```

`localconfig` is x86_64-only; the 8250 serial options stay in its base file
(no overlay needed, no arm64/riscv sections retained).

## Files changed

### New overlay files (32 files)

Eight profiles × four arches (localconfig handled in base, no overlay):

```
configs/tinyconfig-{x86_64,i386,arm64,riscv}.config
configs/allnoconfig-{x86_64,i386,arm64,riscv}.config
configs/defconfig-{x86_64,i386,arm64,riscv}.config
configs/kunitconfig-{x86_64,i386,arm64,riscv}.config
configs/kunitrandconfig-{x86_64,i386,arm64,riscv}.config
configs/allmodconfig-{x86_64,i386,arm64,riscv}.config
configs/randconfig-{x86_64,i386,arm64,riscv}.config
configs/rand500config-{x86_64,i386,arm64,riscv}.config
configs/randdefconfig-{x86_64,i386,arm64,riscv}.config
configs/randkconfigconfig-{x86_64,i386,arm64,riscv}.config
```

Note: `randkconfigconfig` is used by the `kconfig-build` sweep, not `make
all`; overlay files are created for it anyway so `build-kconfig.sh` can apply
them.

### Modified base files (10 files)

Strip all arch-specific serial/FPU sections; keep only arch-neutral options.
`configs/localconfig.config`: also strip arm64/riscv serial sections (they
were dead options — `olddefconfig` always dropped them on x86_64).

### `lib/build.sh`

After step 1b (fragment application), add **step 1b.1** — arch overlay:

```bash
# Step 1b.1: apply arch overlay if present (arch-specific serial, FPU, etc.)
# For rand500config/kunitrandconfig: arch overlay is applied after the
# bootability fragment (step 1b), making it the final layer before olddefconfig.
ARCH_OVERLAY="$SCRIPT_DIR/configs/${CONFIG}-${ARCH}.config"
if [[ -z "${SEED_CONFIG:-}" ]] && [[ -f "$ARCH_OVERLAY" ]]; then
    info "Applying arch overlay: $ARCH_OVERLAY"
    cat "$ARCH_OVERLAY" >> "$PWD/$OUT_DIR/.config"
    if ! kmake olddefconfig; then
        ...die...
    fi
fi
```

For rand500config and kunitrandconfig the random sampling happens before step
1b, so the arch overlay as step 1b.1 naturally lands last.

### `lib/build-kconfig.sh`

After applying `configs/randkconfigconfig.config` (the bootability fragment
for the exhaustive kconfig sweep), apply the arch overlay:

```bash
ARCH_OVERLAY="$SCRIPT_DIR/configs/randkconfigconfig-${ARCH}.config"
if [[ -f "$ARCH_OVERLAY" ]]; then
    cat "$ARCH_OVERLAY" >> "$build_dir/.config"
fi
```

### `CLAUDE.md`

- Add a row in the Key files table documenting the `configs/<profile>-<arch>.config`
  arch overlay pattern.
- Update the Conventions section fragment description:
  > Config fragments: `configs/<profile>.config` (arch-neutral base) +
  > optional `configs/<profile>-<arch>.config` (arch overlay); base applied
  > first, arch overlay second, one `olddefconfig` resolves both.

### `memory/config-profiles.md`

Update fragment description to document base + overlay structure.

## Apply-order detail by config type

| Config type | Step 1a (base) | Step 1b (fragment/base) | Step 1b.1 (arch overlay) | `olddefconfig` |
|---|---|---|---|---|
| Standard (tinyconfig, allnoconfig, defconfig, …) | `make <target>` | `cat configs/<profile>.config` | `cat configs/<profile>-<arch>.config` | once |
| kunitconfig | `make defconfig` | `cat configs/kunitconfig.config` | `cat configs/kunitconfig-<arch>.config` | once |
| rand500config | `make tinyconfig` + rand-sampled | `cat configs/rand500config.config` | `cat configs/rand500config-<arch>.config` | once |
| kunitrandconfig | `make defconfig` + kunit-sampled | `cat configs/kunitrandconfig.config` | `cat configs/kunitrandconfig-<arch>.config` | once |
| randdefconfig | `make defconfig` + random disables | `cat configs/randdefconfig.config` | `cat configs/randdefconfig-<arch>.config` | once |
| localconfig | `zcat /proc/config.gz` + `olddefconfig` | `cat configs/localconfig.config` | _(none — x86_64 only)_ | _(already done)_ |
| allmodconfig | `make allmodconfig` | `cat configs/allmodconfig.config` | `cat configs/allmodconfig-<arch>.config` | once |
| randconfig | `make randconfig` + constraints | `cat configs/randconfig.config` | `cat configs/randconfig-<arch>.config` | once |

## Deferred: BOOT_BASELINE_OPTS

`build.sh` Step 1c auto-corrects required options that `olddefconfig` silently
drops after a kernel Kconfig restructure.  With arch overlays in place the
arch-specific entries in `BOOT_BASELINE_OPTS` (8250, PL011, OF_PLATFORM, FPU)
overlap with the overlay content.

Decision deferred: review after implementation, before opening the PR.  The
safety-net argument favours keeping the array; the simplicity argument favours
removing the arch-specific entries from it.

## Testing plan

1. `make smoke NO_FETCH=1` — kunitconfig + tinyconfig, 4 archs, 30/30 tests.
2. `make full NO_FETCH=1` — 5 bootable configs, 4 archs, ≥ 19/20 PASS.
3. Confirm each arch receives the correct overlay by checking
   `build/<profile>-<arch>/.config` for the expected serial driver option.
4. Confirm missing overlay (e.g. `configs/allmodconfig-x86_64.config` not
   created) does not cause a build error.
