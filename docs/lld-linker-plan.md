# LLD Linker — Plan

Branch: `feat/lld-linker`
Start date: 2026-09-26

---

## Situation

Warm-cache kernel builds (100% ccache hit rate) spend nearly all their wall time in
the vmlinux link step. BFD is single-threaded and slow; LLD links 3–5× faster.
On a Ryzen 7 5800H, localconfig warm builds take ~150s with BFD; defconfig ~35s.
LLD 22.1.8 is already installed on the local machine. Hetzner staging has LLD 14.0.6
(below the Linux 7.x minimum of 17.0.1) and needs an upgrade to benefit.

---

## Problems to Solve

1. **Slow warm builds** — after ccache eliminates compilation, vmlinux linking dominates;
   BFD wastes 80–120s on localconfig, 20–28s on defconfig per arch per warm run.
2. **Silent tool selection** — no visibility into which linker was used; hard to diagnose
   linker-related failures or verify LLD is active.

---

## Goals

1. Auto-detect `ld.lld` at preflight time; use it for all builds when ≥ kernel minimum.
2. Write `LINKER=lld|bfd` to `build.status`; show in report headers (txt, html, mail).
3. `USE_LLD=0` in `local.mk` disables auto-detect for environments with linker issues.
4. CI tests verify detection logic and report output without requiring a full kernel build.

---

## Scope

Files changed:
- `lib/common.sh` — add `detect_lld()` shared helper
- `lib/preflight.sh` — call `detect_lld()` for informational output
- `lib/build.sh` — call `detect_lld()`, add `LD=ld.lld` to `kmake()`, EXIT trap writes `LINKER=`
- `lib/report.sh` — detect `LINKER_USED` from build.status; add to txt/html/mail headers
- `Makefile` — add `USE_LLD ?= 1`, export it
- `tests/ci/test-lld.sh` — CI tests for detection logic and report output
- `docs/lld-linker-plan.md` — this file
- memory + CLAUDE.md — variable and pipeline documentation

No changes to: kernel config fragments, VM/initramfs pipeline, test scripts, report table columns.

---

## Non-goals

- `LLVM=1` (full Clang toolchain) — already supported via `COMPILER=clang`; LLD there is
  implicit and unaffected by this feature.
- Installing LLD on Hetzner — operational step, not harness code.
- Parallel linking (`--threads`) — LLD supports it but gains are marginal vs link-time reduction.

---

## Design decisions

### Auto-detect vs explicit opt-in

Auto-detect (like ccache) was chosen over `USE_LLD=1` because LLD is a pure speedup with
no behaviour change for passing builds. The `USE_LLD=0` escape hatch handles edge cases
without requiring users to discover a new variable to get the benefit.

### detect_lld() in common.sh

Both `preflight.sh` (informational) and `build.sh` (decision) need the same check.
A shared function in `common.sh` avoids duplication and keeps the version comparison logic
in one place. Both scripts already source `common.sh`.

`preflight.sh` is a subprocess of the Makefile `build:` target and cannot export variables
to `build.sh` (another subprocess). Each script runs `detect_lld()` independently — the
check is ~5 ms and idempotent.

### Minimum version from kernel's scripts/min-tool-version.sh

The kernel tree's own `scripts/min-tool-version.sh lld` is authoritative and auto-updates
across kernel versions. Hardcoding 17.0.1 would silently become stale when a future kernel
raises the minimum. Fallback to 17.0.1 when KERNEL_TREE lacks the script (very old trees).

### LINKER written via EXIT trap in build.sh

There are ~18 `printf 'STATUS=...' > "$STATUS_FILE"` calls in build.sh (one PASS, one TIMEOUT,
~16 FAIL paths). Adding `LINKER=%s` to all of them is mechanical and error-prone. A single
`trap 'printf "LINKER=%s\n" "${LINKER:-bfd}" >> "$STATUS_FILE"' EXIT` appends the field on any
exit path, including error paths handled by `die()`, without touching the existing writes.

### LINKER in report header, not per-row

LINKER is a run-level property — all (config, arch) combos in one `make all` invocation use
the same linker. Adding it as a per-row column would widen the table for no extra information.
A single `Linker: lld` line after `Host:` in all three report formats (txt, html, mail) is
sufficient and visible.

---

## Testing strategy

- **detect_lld() unit tests** — stub `ld.lld` and `scripts/min-tool-version.sh` via isolated
  PATH; verify return code and variable values for: good version, too-old version, absent, disabled.
- **preflight output** — run `lib/preflight.sh` with stubs; grep output for expected lines.
- **report LINKER field** — create fake `build.status` files with/without `LINKER=`; run
  `lib/report.sh` and check output contains `Linker: lld` or `Linker: bfd`.
- **No full build/boot CI test** — a kernel build takes minutes and requires KERNEL_TREE;
  covered by `make smoke` / `make dev-test` after implementation.

---

## Testing commands

```sh
# Verify preflight shows LLD info
make preflight
# Expected: "Preflight: LLD 22.1.8 ≥ 17.0.1 — using ld.lld"

# Verify escape hatch
USE_LLD=0 make preflight
# Expected: no LLD line; "Preflight: all checks passed"

# Verify LD=ld.lld appears in build log
make build NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64
grep 'LD=ld.lld' build/tinyconfig-x86_64/build.log
# Expected: at least one match

# Verify build.status has LINKER=lld
grep LINKER build/tinyconfig-x86_64/build.status
# Expected: LINKER=lld

# Full CI gate
make lint
make ci-test
make dev-test
```
