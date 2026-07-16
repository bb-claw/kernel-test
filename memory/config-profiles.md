# Config Profiles

## Overview

| Profile | Boot tested | Base | Fragment | Notes |
|---|---|---|---|---|
| `defconfig` | yes | arch default | none | Broad baseline; most subsystems enabled |
| `tinyconfig` | yes | minimal | `configs/tinyconfig.config` | Near-empty; fragment pins bootability options |
| `allnoconfig` | yes | all-no | `configs/allnoconfig.config` | Absolute minimum boot path |
| `kunitconfig` | yes | defconfig | `configs/kunitconfig.config` | KUnit framework + core test suites; KTAP results shown as kunit:N/N |
| `kunitrandconfig` | no | defconfig | `configs/kunitrandconfig.config` | Build-only: all KUnit test modules available on defconfig base (enumerated from randconfig, olddefconfig drops invalid); random set per run — rebuild required each time; use `kunitconfig` for deterministic KUnit boot testing |
| `rand500config` | yes | tinyconfig | `configs/rand500config.config` | 500 random =y lines sampled from constrained randconfig |
| `randdefconfig` | yes | defconfig | `configs/randdefconfig.config` | 300 random options disabled; heavy subsystems forced off |
| `localconfig` | yes | /proc/config.gz | `configs/localconfig.config` | Daily-driver: full Manjaro config + laptop hardware fragment; `make install` deploys to /boot |
| `allmodconfig` | no | all-modules | none | Build-only: image too large for minimal initramfs |
| `randconfig` | no | random | `configs/randconfig.config` | Build-only: unpredictable boot; value is compile coverage |

Makefile variables:
```
CONFIGS          = tinyconfig allnoconfig defconfig kunitconfig kunitrandconfig allmodconfig randconfig rand500config randdefconfig
BUILD_ONLY_CONFIGS = allmodconfig randconfig kunitrandconfig
BOOT_CONFIGS       = (CONFIGS minus BUILD_ONLY_CONFIGS)
```

Note: `localconfig` is not in the default `CONFIGS` list (requires `/proc/config.gz`); run with no timeout:
```sh
make build   NO_FETCH=1 CONFIGS=localconfig ARCHS=x86_64 BUILD_TIMEOUT=0
make install            CONFIGS=localconfig ARCHS=x86_64
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
- `CONFIG_RCU_TORTURE_TEST=n CONFIG_LOCK_TORTURE_TEST=n` — spawn permanent kernel threads flooding the serial console, starving test scripts
- `CONFIG_KUNIT=n` — on tinyconfig base kunit_try_catch fails to catch the self-test's intentional NULL dereference (PREEMPT_LAZY + i386); use kunitconfig/kunitrandconfig instead

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

## localconfig (special handling in build.sh)

Hardware: Lenovo IdeaPad — AMD Ryzen 7 5800H + MediaTek MT7921 WiFi (PCIe)
Purpose: daily-driver build based on the full running Manjaro kernel config.

1. `zcat /proc/config.gz` → `$OUT_DIR/.config` (requires `CONFIG_IKCONFIG_PROC=y`)
2. `make olddefconfig` — adapts existing config to the new kernel version
3. Apply `configs/localconfig.config` fragment (step 1b standard path)
4. `make olddefconfig`

Fragment pins:
- `CONFIG_BLK_DEV_NVME=y CONFIG_NVME_CORE=y` — NVMe SSDs
- `CONFIG_MT7921E=y` — MediaTek MT7921 802.11ax PCIe WiFi
- `CONFIG_BT=y CONFIG_BTUSB=y CONFIG_BT_MTK=y` — Bluetooth (btmtk)
- `CONFIG_AMD_PMC=y` — S2Idle suspend for Ryzen 5000
- `CONFIG_SENSORS_K10TEMP=y` — AMD die temperature via hwmon
- `CONFIG_IDEAPAD_LAPTOP=y` — fn-keys, battery conservation, camera toggle
- `CONFIG_CRYPTO_AES_NI_INTEL=y` — AES-NI hardware acceleration
- `CONFIG_BTRFS_FS=y CONFIG_EXFAT_FS=y` — Btrfs and exFAT
- `CONFIG_LOCALVERSION="-localconfig"` — distinguishes from distro kernel in uname -r

Build time: 15–25 min on 16 cores (full Manjaro config). Use `BUILD_TIMEOUT=0`.
Install: `make install CONFIGS=localconfig ARCHS=x86_64` → modules, vmlinuz, mkinitcpio preset, GRUB.

---

## CONFIG_SHA256 Fingerprinting

After the build completes, `build.sh` recomputes:
```sh
CONFIG_SHA256=$(sha256sum "$OUT_DIR/.config" | awk '{print $1}')
```
Stored in `build.status` as `CONFIG_SHA256=<hash>` at each STATUS=PASS/FAIL/TIMEOUT write.
The hash is taken post-build so it reflects any `syncconfig` changes the kernel build made.
`report.sh` copies `.config` to the report dir and re-verifies the hash → `OK` or `MISMATCH`.
