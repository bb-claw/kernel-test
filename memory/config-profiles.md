# Config Profiles

## Overview

| Profile | Boot tested | Base | Fragment | Notes |
|---|---|---|---|---|
| `defconfig` | yes | arch default | none | Broad baseline; most subsystems enabled |
| `tinyconfig` | yes | minimal | `configs/tinyconfig.config` | Near-empty; fragment pins bootability options |
| `allnoconfig` | yes | all-no | `configs/allnoconfig.config` | Absolute minimum boot path |
| `rand500config` | yes | tinyconfig | `configs/rand500config.config` | 500 random =y lines sampled from constrained randconfig |
| `randdefconfig` | yes | defconfig | `configs/randdefconfig.config` | 300 random options disabled; heavy subsystems forced off |
| `allmodconfig` | no | all-modules | none | Build-only: image too large for minimal initramfs |
| `randconfig` | no | random | `configs/randconfig.config` | Build-only: unpredictable boot; value is compile coverage |

Makefile variables:
```
CONFIGS          = tinyconfig allnoconfig defconfig allmodconfig randconfig rand500config randdefconfig
BUILD_ONLY_CONFIGS = allmodconfig randconfig
BOOT_CONFIGS       = (CONFIGS minus BUILD_ONLY_CONFIGS)
```

---

## Fragment Mechanism

Fragments are applied **after** the kernel config target, before build:
```sh
cat "configs/$CONFIG.config" >> "$OUT_DIR/.config"
make olddefconfig   # resolves all dependency conflicts
```
`KCONFIG_ALLCONFIG` is NOT used — `tinyconfig` overrides it internally.

---

## rand500config (special handling in build.sh)

1. `make tinyconfig` — tiny bootable base
2. Generate fresh `randconfig` in a temp dir
3. Apply `configs/randconfig.config` constraints to the temp dir (no modules, no heavy subsystems)
4. Run `olddefconfig` on temp dir
5. `shuf -n 500` on `CONFIG_*=y` lines → append to `$OUT_DIR/.config`
6. Apply `configs/rand500config.config` bootability fragment
7. `make olddefconfig` — resolve all dependencies

The 500-line count compensates for dependency attrition: many sampled options get
disabled by `olddefconfig` because their prerequisites are absent in the tinyconfig base.

Saves: `rand-source.config` (full constrained randconfig), `rand-sampled.config` (500 lines).

---

## randdefconfig (special handling in build.sh)

1. `make defconfig` — broad, coherent baseline
2. `grep '^CONFIG_[A-Z0-9_]*=[ym]$' .config | shuf -n 300 | sed 's/=[ym]$/=n/'` → append
3. Apply `configs/randdefconfig.config`: force DRM/SOUND/STAGING/INFINIBAND/MEDIA_SUPPORT off,
   re-pin bootability options
4. `make olddefconfig`

Saves: `randdef-disabled.config` (300 disabled lines).
Build time: reliably under 5 min on 16-core machine (heavy subsystem force-off).

---

## randconfig constraints (configs/randconfig.config)

Applied to both:
- The source randconfig for rand500config (temp dir)
- The randconfig build-only profile

Excludes:
- `CONFIG_MODULES=n` — forces all =m to =n, shrinks build surface dramatically
- `CONFIG_DRM=n CONFIG_SOUND=n CONFIG_STAGING=n CONFIG_INFINIBAND=n CONFIG_MEDIA_SUPPORT=n` — 5+ min each when built-in
- `CONFIG_KCOV=n CONFIG_KASAN=n CONFIG_KMSAN=n CONFIG_KCSAN=n CONFIG_KFENCE=n CONFIG_UBSAN=n` — sanitizers crash on tinyconfig base (no per-task coverage buffer, OOM on 512M VM)

---

## Bootability Fragment Contents (shared pattern)

All bootable configs that need a fragment pin these options:
```
CONFIG_PRINTK=y
CONFIG_TTY=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_TMPFS=y
```

`randdefconfig.config` adds the heavy subsystem disables on top of this.

---

## CONFIG_SHA256 Fingerprinting

After `olddefconfig` completes (config fully resolved), `build.sh` computes:
```sh
CONFIG_SHA256=$(sha256sum "$OUT_DIR/.config" | awk '{print $1}')
```
Stored in `build.status` as `CONFIG_SHA256=<hash>`.
`report.sh` copies `.config` to the report dir and re-verifies the hash → `OK` or `MISMATCH`.
