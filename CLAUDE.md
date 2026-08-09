# CLAUDE.md — kernel-test

## Git Workflow

- **All changes go through a PR** — no direct commits to `main`
- **Branch naming**: `<type>/<kebab-description>` (feat/, fix/, docs/, chore/, ci/, test/)
- **Commit messages**: `<type>[(<scope>)]: <description>` — enforced by `.githooks/commit-msg`
- **Merging**: always merge commits (never squash or rebase); PR title follows the same format
- **Before a PR**: `make all NO_FETCH=1 CONFIGS=tinyconfig`; for `tests/` changes: `make all NO_FETCH=1`

---

## Overview

Bash harness for testing Linux release-candidate kernels: build under multiple config profiles, boot in QEMU/KVM with a minimal Toybox initramfs, run tests inside the VM, write HTML/text report.

- **Entry point**: `Makefile` — all commands via `make <target> [VAR=value]`
- **Language**: Bash for all harness scripts (`set -euo pipefail`); POSIX sh for VM test scripts
- **Archs**: x86_64, i386 (KVM); arm64, riscv (TCG — slower, 1 G RAM, `TIMEOUT×2`)
- **Userland**: Toybox 0.8.14 static binary in cpio initramfs (`TOYBOX_VERSION` pin)
- **Data**: builds in `build/`, reports in `DATA_REPO/reports/` (default `~/git/kernel-test-data/`)

---

## Key Commands

```sh
make fetch                                     # fetch latest kernel for this clone (preset-aware)
make all NO_FETCH=1                            # full pipeline: build + boot + test + report
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig  # fast iteration: repack + re-run tests only
make smoke                                     # quick sanity: kunitconfig + tinyconfig, all archs
make ns-smoke                                  # namespace smoke: kunitnsconfig + tinynsconfig
make ns-full                                   # namespace full: 5 ns-variant configs
make extended                                  # full then ns-full (10 configs); for staging automation
make lint                                      # Tier 1 CI: shellcheck, inventory, sizes, PR title
make ci-test                                   # Tier 2 CI: tests/ci/test-*.sh suite
make bootstrap                                 # install deps, download Toybox, activate git hooks
make install CONFIGS=localconfig ARCHS=x86_64  # deploy to /boot (Arch/Manjaro only)
make info                                      # show currently checked-out kernel
make diff                                      # diff latest vs previous run
make baseline                                  # pin a reference run for regression comparison
make kconfig-check SUBSYSTEM=<name>            # static Kconfig dependency analysis
make bisect CONFIG_FILE=<path>                 # binary-search a failing archived config
make verify-patch FILES=... [BASE=<ref>]       # build-test a patch across arches and compilers
make hw-bootstrap [DRY_RUN=1]                  # install hardware test infra (needs sudo)
make hw-deploy                                 # copy kernel+initramfs+DTB to TFTP_DIR
make hw-test BOARD_TTY=/dev/ttyUSB0           # serial capture on real board (≡ make test)
make hw BOARD_TTY=/dev/ttyUSB0                # build → hw-deploy → hw-test → report
```

### Fetch modes (per-clone preset)

| Clone dir | `make fetch` does |
|---|---|
| `kernel-test` | latest `v*-rc*` tag via `git ls-remote --depth=1` |
| `kernel-test-stable` | latest `vX.Y.*` tag (`STABLE_RELEASE=X.Y` set by preset) |
| `kernel-test-stable-rc` | `git fetch origin linux-X.Y.y` + `git reset --hard FETCH_HEAD` |
| `kernel-test-next` | **error** — use `make fetch-next` (linux-next has no rc tags) |

---

## Code Quality Gates

Pre-push hook enforces all of the following — fix before pushing:

- **shellcheck** on all tracked `.sh` files
- **executable bit** on all `tests/**/*.sh`
- **test-inventory coverage** — every `tests/custom/*.sh` name in `memory/test-inventory.md`
- **design doc** — `docs/<slug>-plan.md` required for `feat/*` and `fix/*` branches
- **memory files ≤ 150 lines** — `memory/*.md` (except `MEMORY.md`)
- **CLAUDE.md ≤ 200 lines** — this file
- **no `awk`** in VM test scripts — not compiled into the Toybox binary; use `grep | cut`

---

## VM Test Script Rules

VM tests run under Toybox sh (POSIX only). Critical pitfalls:

- **No `if out=$(cmd); then`** — Toybox sh bug: the variable assignment always exits 0, silently masking the command's real exit code. Use `cmd > /tmp/out.txt 2>&1` (file redirect) to capture output.
- **No `awk`** — not in Toybox; use `grep | cut`
- **No `[[ ]]`** — use `[ ]` (POSIX)
- **No `elif`** — Toybox 0.8.9 bug: both branches execute; use nested `if/else/fi`
- **No `$_varname`** — Toybox parses `$_x` as `$_` (last-arg special var) + literal `x`; always use plain names without leading underscores
- **`$(( ))`** — avoid in while loops (OOM in 512 MB VM); use `for i in 1 2 3 ...`
- **`/bin/sh`** — always full path when forking a shell; bare `sh` hits Toybox NOFORK and loses stdout
- **No `\<newline>` inside pipelines** — Toybox sh bug: `cmd | grep -q 'pat' \` + newline passes the next line's leading whitespace as a filename to grep; use `if cmd | grep -q 'pat'; then ok; else fail; fi`
- See `memory/code-quality.md` for the full pitfall list and pattern template

---

## How to Add a Test

1. Create `tests/custom/NNN_my-test.sh` (3-digit slot, leave gaps: 010, 020, …); **next slot: 420_**
2. `exit 0` = pass; non-zero = fail; print `ok: msg` / `FAIL: msg` / `skip: msg`
3. Harness injects all `tests/custom/*.sh` into the initramfs and runs them sequentially in the VM
4. Stage both the script and the updated `memory/test-inventory.md` — pre-commit enforces this
5. If the test gates on a config capability (ns, watchdog, perf, arena): check the matching `/tests/<feature>-enabled` marker as the *first* guard (written by `lib/initramfs.sh` at build time); runtime probing is the second guard (double-guard pattern)
6. If the test needs C code: add a subdir under `tests/programs/` (see `perf-event/` or `arena-test/` as patterns); add build + copy steps to `lib/bootstrap.sh` and `lib/initramfs.sh`; add a skip guard in the shell script for the absent-binary case

---

## What NOT To Do

- No Python, Go, or non-shell dependencies without explicit approval
- No root required for build steps (only QEMU via KVM group membership)
- No hardcoded paths — use `KERNEL_TREE`, `BUILD_DIR`, `REPORT_DIR` variables
- No build artifacts, ccache, or reports committed — all gitignored
- Never write to the kernel source tree — all build artifacts go under `build/`

---

## Memory Files

@memory/project.md
@memory/workflows.md
@memory/config-profiles.md
@memory/test-inventory.md
@memory/code-quality.md
@memory/patch-workflow.md
