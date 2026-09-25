# make info speedup — Plan

Branch: `fix/make-info-speed`
Start date: 2026-09-25

---

## Situation

`make info` (and every other `make` invocation) was taking 20+ seconds because the
`KERNEL_VERSION` variable is computed at Makefile parse time via `$(shell ...)`, and
the fallback path called `make -s -C "$(KERNEL_TREE)" kernelversion`. This triggers
the full Kbuild machinery every time, even for targets that don't use the kernel version.

---

## Problems to Solve

1. **`KERNEL_VERSION` fallback invokes Kbuild** — `make -s -C KERNEL_TREE kernelversion` parses
   the entire Kconfig/Kbuild machinery; takes 20+ seconds on every `make` invocation,
   making interactive use (e.g. `make info`) painfully slow.

---

## Goals

1. `make info` completes in under 1 second under normal operation (version file present).
2. `make info` completes in under 1 second even when the version file is absent (grep fallback).

---

## Scope

Files/components changed:
- `Makefile` — replace `make -s -C KERNEL_TREE kernelversion` with inline grep of `KERNEL_TREE/Makefile`

No changes to: `lib/common.sh` (already has `read_kernel_makefile_version()`; that function
is not reusable from Makefile `$(shell ...)` context), test scripts, CI tests.

---

## Non-goals

- Caching `KERNEL_VERSION` across invocations (not needed; grep is fast enough)
- Removing other `$(shell ...)` calls in the Makefile

---

## Design decisions

### Inline grep vs. calling read_kernel_makefile_version()

`lib/common.sh:read_kernel_makefile_version()` already implements the same logic for
Bash scripts, but it cannot be called from a Makefile `$(shell ...)` block without
sourcing the entire lib (which has other side-effects). Inlining the grep is simpler
and consistent with what the function does: four `grep -m1` + `sed` calls on
`KERNEL_TREE/Makefile`. The comment in the Makefile explains why `make kernelversion`
is intentionally avoided.

### SUBLEVEL=0 means omit the patch component

Mainline RC kernels have `SUBLEVEL = 0` and format as `v7.2-rc3` (not `v7.2.0-rc3`).
The condition `[ "${_s:-0}" -eq 0 ]` matches this: emit `v%s.%s%s` when SUBLEVEL is 0,
`v%s.%s.%s%s` otherwise (stable releases like `v7.1.5`).

---

## Testing strategy

- **Timing** — `time make info` before and after; expect <1s after fix
- **Correctness** — version string format matches `vX.Y-rcN` for mainline, `vX.Y.Z` for stable
- **No CI test** — pure Makefile parse-time behaviour; no harness hook to invoke it; manual timing is the gate

---

## Testing commands

```sh
# Always run before pushing any branch
make dev-test
# Expected: exit 0, ≥70% decision paths covered within time budget

# 1. Timing
time make info
# Expected: real < 1s

# 2. Correct version string
make info
# Expected: version line shows vX.Y[-rcN] matching kernel Makefile
```
