# configs/

Kconfig fragments applied after the kernel config target runs.

## How they work

`lib/build.sh` appends the fragment to the out-of-tree `.config`, then runs
`make olddefconfig` to resolve all dependency conflicts:

```sh
cat configs/<profile>.config >> build/<profile>-<arch>/.config
make olddefconfig
```

`KCONFIG_ALLCONFIG` is intentionally not used — some targets (e.g. `tinyconfig`)
override it internally, silently discarding the fragment.

## Files

| File | Profile | Purpose |
|---|---|---|
| `tinyconfig.config` | `tinyconfig` | Re-enable minimum bootability options stripped by tinyconfig |
| `allnoconfig.config` | `allnoconfig` | Re-enable minimum bootability options stripped by allnoconfig |
| `rand500config.config` | `rand500config` | Same bootability options for the tinyconfig+random base |
| `randdefconfig.config` | `randdefconfig` | Force heavy subsystems off (DRM/SOUND/STAGING) + bootability options |
| `randconfig.config` | `randconfig` | Exclude modules and heavy subsystems to stay within BUILD_TIMEOUT |
| `localconfig.config` | `localconfig` | Hardware options for Lenovo AMD Ryzen 7 5800H + MT7921 WiFi |

## Adding a fragment

Create `configs/<profile>.config` with standard Kconfig lines (`CONFIG_FOO=y`,
`# CONFIG_BAR is not set`). The fragment is applied automatically if the filename
matches the profile name passed to `make build CONFIGS=<profile>`.

Bootability options all profiles need for the QEMU VM:

```
CONFIG_TTY=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_TMPFS=y
```
