# configs/

Kconfig fragments applied after the kernel config target runs.

## How they work

`lib/build.sh` appends the fragment to the out-of-tree `.config`, then runs
`make olddefconfig` to resolve all dependency conflicts:

```sh
cat configs/<profile>.config >> build/<profile>-<arch>/.config
# optionally: cat configs/<profile>-<arch>.config >> build/<profile>-<arch>/.config
make olddefconfig
```

`KCONFIG_ALLCONFIG` is intentionally not used — some targets (e.g. `tinyconfig`)
override it internally, silently discarding the fragment.

## Two-layer fragment pattern

Each profile uses up to two files applied in order before one `olddefconfig` pass:

1. `configs/<profile>.config` — arch-neutral base (PRINTK, TTY, INITRD, BINFMT, TMPFS)
2. `configs/<profile>-<arch>.config` — arch overlay (serial driver, FPU); absent = silently skipped

## Fragment files

| File | Profile | Purpose |
|---|---|---|
| `tinyconfig.config` | `tinyconfig` | Arch-neutral bootability options (PRINTK, TTY, INITRD, BINFMT, TMPFS) |
| `allnoconfig.config` | `allnoconfig` | Same as tinyconfig.config |
| `kunitconfig.config` | `kunitconfig` | Enable KUnit framework + core lib/ and mm/ test suites (applied on defconfig base) |
| `kunitrandconfig.config` | `kunitrandconfig` | KUnit=y + core suites baseline; random KUNIT modules added on top |
| `rand500config.config` | `rand500config` | Bootability fragment for tinyconfig+random base |
| `randdefconfig.config` | `randdefconfig` | Force heavy subsystems off (DRM/SOUND/STAGING) + bootability options |
| `randconfig.config` | `randconfig` | Exclude modules + heavy subsystems + sanitizers to stay within BUILD_TIMEOUT |
| `randkconfigconfig.config` | `kconfig-build` sweep | Same as rand500config.config; applied to tinyconfig base before the option under test |
| `localconfig.config` | `localconfig` | Hardware options for Lenovo AMD Ryzen 7 5800H + MT7921 WiFi |
| `canary.config` | `CANARY=1` | `CONFIG_BOOT_CANARY=y` + `CONFIG_DEBUG_42=y` + `CONFIG_PROC_FS=y` |

## Arch overlay files

| File | Arch | Contents |
|---|---|---|
| `*-x86_64.config` | x86_64 | `CONFIG_SERIAL_8250=y` + `CONFIG_SERIAL_8250_CONSOLE=y` |
| `*-i386.config` | i386 | Same as x86_64 |
| `*-arm64.config` | arm64 | `CONFIG_SERIAL_AMBA_PL011=y` + `CONFIG_SERIAL_AMBA_PL011_CONSOLE=y` |
| `*-riscv.config` | riscv | `CONFIG_SERIAL_8250=y` + `CONFIG_SERIAL_OF_PLATFORM=y` + `CONFIG_FPU=y` |

`localconfig` has no arch overlay (x86_64-only; 8250 options kept in its base fragment).

## archive_passed/ and archive_failed/

Committed config archives populated by `make config-archive`. One `.config` per unique
SHA256. Filenames encode the config profile, arch, kernel version, and SHA256 hash;
failed configs additionally encode the failure stage and symptom.
