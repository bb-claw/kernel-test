# KT-001 — toybox-revert-0814: plan

**Story**: [`docs/stories/KT-001-toybox-revert-0814.md`](../stories/KT-001-toybox-revert-0814.md)
**Branch**: `fix/KT-001-toybox-revert-0814`
**Status**: shipped  # in-progress → shipped (PR #129, merged to main)

---

## Situation

`chore/bump-toybox-0.8.15` moved the pinned Toybox from 0.8.14 → 0.8.15. Toybox
0.8.15's `sh` deadlocks when a shell builtin writes more than the 64 KB pipe
buffer into a pipe (`printf '%s\n' "$KLOG" | grep …` in `030_check-dmesg`,
`$KLOG` ≈ 95 KB). The VM freezes at test 030 with the console idle and ~937 MB
free (not OOM). 0.8.14 does not. Revert the pin.

---

## Problems to solve

1. **VM test runs hang under 0.8.15** — every `kunitconfig` boot freezes at
   `030_check-dmesg`; the harness reports `BOOT=FAIL … TEST_DONE not reached`,
   which reads as a kernel crash and misdirects debugging.
2. **Mispin is the default** — `TOYBOX_VERSION` defaults to 0.8.15 in three
   selection points plus a CI assertion, so a clean checkout reproduces the hang.

---

## Goals

One-to-one with the story's Gherkin Scenarios.

1. `make all NO_FETCH=1 CONFIGS=kunitconfig ARCHS=arm64` reaches `TEST_DONE`,
   52/52, Overall PASS, exit 0 (on 7.3.6 and 7.3.7-rc1).
2. `TOYBOX_VERSION` reads `0.8.14` at every selection point; `make ci-test`
   (`test-makefile-defaults.sh`) passes.

---

## Evidence (why 0.8.15 is the cause)

Controlled 2×2, each cell 6 clean runs, toybox binary SHA re-verified per run
(0.8.14 = `223b5ff…`, 0.8.15 = `be360e78…`, both confirmed by executing
`toybox --version` under `qemu-aarch64-static`):

| kernel \ toybox | 0.8.14 | 0.8.15 |
|---|---|---|
| 7.3.6     | PASS 6/6 | HANG 6/6 |
| 7.3.7-rc1 | PASS 6/6 | HANG 6/6 |

Hang is 100% determined by the Toybox version and 0% by the kernel. All hangs
stop at `TEST RUN: 030_check-dmesg`.

---

## Scope

Files / components changed:
- `Makefile` — `TOYBOX_VERSION ?= 0.8.15` → `0.8.14`
- `lib/bootstrap.sh` — fallback default `:-0.8.15` → `:-0.8.14`
- `lib/download-toybox.sh` — fallback default `:-0.8.15` → `:-0.8.14`
- `tests/ci/test-makefile-defaults.sh` — flip the explicit `0.8.15` assertion to `0.8.14`
- `tests/ci/test-report.sh`, `test-combined-report.sh`, `test-extended-perf-report.sh`
  — fixture `TOYBOX_VERSION="0.8.15"` → `"0.8.14"` (consistency, not asserted)
- `CLAUDE.md` — "Toybox 0.8.15 static binary" → "0.8.14"
- `docs/stories/KT-001-*.md`, `docs/stories/INDEX.md`, this plan — story + index

No changes to: `scripts/config-bisect.sh` (independent legacy `:-0.8.9` default);
`DESIGN.md` (already states 0.8.14); the committed `cache/` (gitignored — the
binary re-downloads via the version-stamp mismatch).

---

## Non-goals

- Rewriting `030_check-dmesg` to grep the on-disk log file instead of piping a
  large shell variable (separate hardening story — would make the harness immune
  regardless of Toybox version, but is not required to fix the regression).
- Reporting/fixing the Toybox 0.8.15 `sh` pipe bug upstream.

---

## Design decisions

### Revert the pin rather than patch the test

Option chosen: restore the known-good 0.8.14 pin. It is the minimal, lowest-risk
change that restores a green pipeline across all configs/arches immediately, and
0.8.14 was the shipped baseline for months. Rejected: (a) patch only
`030_check-dmesg` — leaves the latent 0.8.15 bug to bite any future >64 KB pipe;
(b) jump to a newer Toybox — unreleased / unvalidated here.

---

## Breaking changes

- [x] None — strictly additive or internal.
- [ ] Yes — describe:

Reverts a dependency pin to a prior-shipped value; no CLI, output-format, or
semantics change for callers. The `cache/` binary re-syncs automatically.

---

## Rollout

- [x] `README.md` updated (if public make target or variable changed) — N/A, README does not pin the version
- [x] `memory/` files updated — N/A (no memory file pins the Toybox version; `CLAUDE.md` overview line updated)

---

## Shipping evidence

| Gate | Command | Result |
|---|---|---|
| Pin consistent | `make ci-test` (`test-makefile-defaults.sh`) | PASS (25/0) |
| Full local CI | `make ci` (lint → programs → ci-test) | PASS — ci-test 52/52 |
| Doc checks | `make check-docs` (verify-plan-docs + verify-index-status) | PASS |
| Binary re-sync | `lib/download-toybox.sh x86_64` | re-downloads 0.8.14 (`836ba9d6`) via stamp mismatch |
| Regression fixed | `make all NO_FETCH=1 CONFIGS=kunitconfig ARCHS=arm64`, 2×2 × 6 runs | 0.8.14 PASS 6/6, 0.8.15 HANG 6/6 — on both 7.3.6 and 7.3.7-rc1 |
