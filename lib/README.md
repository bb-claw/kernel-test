# lib/

Pipeline scripts called by the `Makefile`. Each script handles one stage.

## Scripts

| Script | Make target | Role |
|---|---|---|
| `fetch.sh` | `make fetch` | `git fetch` + auto-checkout of the latest `-rc` tag (or stable release) |
| `checkout.sh` | `make checkout TAG=` | Fetch and checkout a specific tag or commit |
| `build.sh` | `make build` | Kernel build with ccache, out-of-tree `O=build/<config>-<arch>/` |
| `initramfs.sh` | `make initramfs` | Assemble BusyBox cpio initramfs; inject test scripts |
| `vm.sh` | `make test` | Launch QEMU/KVM, capture serial console, count test pass/fail markers |
| `report.sh` | `make report` | Collate results; write `summary.html` and `summary.txt` |
| `install.sh` | `make install` | Install built kernel to `/boot`; update mkinitcpio + GRUB (Arch/Manjaro) |
| `bootstrap.sh` | `make bootstrap` | Install build/test dependencies (distro-aware, needs sudo) |
| `common.sh` | sourced by others | Shared helpers: `log`/`info`/`warn`/`die`, `require_env`, `is_build_only` |

## Conventions

- `#!/bin/bash` + `set -euo pipefail` on every script
- Invoked as subprocesses by the Makefile (never sourced), so they do not share shell state
- All paths use `$KERNEL_TREE`, `$BUILD_DIR`, `$REPORT_DIR` — never hardcoded
- Error paths write `STATUS=FAIL` to the status file before calling `die`
- `common.sh` is the only script that is sourced (by the others via `. "$(dirname "$0")/common.sh"`)
