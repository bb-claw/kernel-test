# scripts/

On-demand tools invoked explicitly (not part of the `make all` pipeline).

| Script | Invoked by | Purpose |
|---|---|---|
| `kconfig-check.sh` | `make kconfig-check SUBSYSTEM=<name>` | Static analysis: scan a subsystem for missing Kconfig `select` dependencies |
| `kconfig-enumerate.sh` | `scripts/build-kconfig.sh` | Enumerate all `config`/`menuconfig` entries from a subsystem Kconfig file |
| `build-kconfig.sh` | `make kconfig-build SUBSYSTEM=<name>` | Exhaustive per-option build+boot sweep for all options in a subsystem Kconfig |
| `config-archive.sh` | `make config-archive` | Scan all `reports/*/` and populate `configs/archive_passed/` + `configs/archive_failed/` |
| `config-bisect.sh` | `make bisect CONFIG_FILE=<path>` | Binary-search a failing archived config to find the responsible option(s) |
| `canary-patch.sh` | `make canary-patch` | Patch `KERNEL_TREE/drivers/misc/` with boot canary + debug_42 built-in modules |
| `migrate-reports.sh` | manual | Rename old-format report dirs to the new label-prefixed format |

See `CLAUDE.md` Key files table for full descriptions.
