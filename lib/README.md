# lib/

Core pipeline scripts invoked by the `Makefile`. Each script handles one stage.

## Scripts

| Script | Make target | Role |
|---|---|---|
| `fetch.sh` | `make fetch` | `git fetch` + auto-checkout of the latest `-rc` tag (or stable release) |
| `fetch-stable-rc.sh` | `make fetch-stable-rc` | Fetch stable-rc rolling branch tip; reset HEAD |
| `fetch-next.sh` | `make fetch-next` | Fetch linux-next `origin/master`; reset HEAD |
| `checkout.sh` | `make checkout TAG=` | Fetch and checkout a specific tag or commit |
| `build.sh` | `make build` | Kernel build with ccache, out-of-tree `O=build/<config>-<arch>/` |
| `initramfs.sh` | `make initramfs` | Assemble Toybox cpio initramfs; inject test scripts |
| `vm.sh` | `make test` | Launch QEMU/KVM (or TCG for arm64/riscv), capture serial console, count test pass/fail + KUnit KTAP |
| `report.sh` | `make report` | Collate results; write `summary.html`, `summary.txt`, `summary.mail.txt` |
| `diff.sh` | `make diff` | Compare two report dirs for per-test regressions/fixes; called by `report.sh` automatically |
| `install.sh` | `make install` | Install built kernel to `/boot`; update mkinitcpio + GRUB (Arch/Manjaro) |
| `dmesg.sh` | `make dmesg` | Capture and analyse host kernel dmesg; diff warning/error lines vs previous capture |
| `bootstrap.sh` | `make bootstrap` | Install build/test dependencies (distro-aware, needs sudo); download Toybox binaries |
| `common.sh` | sourced by others | Shared helpers: `log`/`info`/`warn`/`die`, `require_env`, `is_build_only`; arch helpers: `arch_cross_compile`, `arch_kernel_image`, `arch_toybox_name`, `apply_arch_overlay` |

## Conventions

- `#!/bin/bash` + `set -euo pipefail` on every script
- Invoked as subprocesses by the Makefile (never sourced), so they do not share shell state
- All paths use `$KERNEL_TREE`, `$BUILD_DIR`, `$REPORT_DIR` — never hardcoded
- Error paths write `STATUS=FAIL` to the status file before calling `die`
- `common.sh` is the only script that is sourced (by the others via `. "$REPO_ROOT/lib/common.sh"`)
