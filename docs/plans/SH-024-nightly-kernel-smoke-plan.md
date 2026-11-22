# SH-024 — nightly-kernel-smoke: plan

**Story**: Tracked in shepherd ([SH-024](https://github.com/bboortz/shepherd/blob/main/docs/stories/SH-024-kernel-test-nightly.md))
**Branch**: `feat/SH-024-nightly-kernel-smoke`
**Status**: in-progress

---

## Situation

Kernel-test adopted the SH-019 contract (including `ci-nightly` → `ci-nightly-body` → `smoke` which builds tinyconfig + kunitconfig kernels). What's missing: the GHA workflow that triggers it on cron. Without it, the slow-lane smoke never runs; regressions in the kernel build surface only when a human remembers to `make smoke` locally.

---

## Problems to solve

1. No scheduled `make ci-nightly` trigger — regressions lurk until manual run.
2. ccache not warmed between runs — cold defconfig build takes ~647s vs ~99s hot (Desaulniers 2018).

---

## Goals

1. `.github/workflows/ci-nightly.yml` exists; dispatches on `cron: "30 2 * * *"`.
2. `workflow_dispatch` also permitted for manual re-runs.
3. `timeout-minutes: 120` per shepherd contract.
4. ccache cached across runs via `actions/cache` keyed on Makefile + tests/.
5. Failures → needs-human issue via the `ci-nightly-body` wrapper's trap (already in the Makefile from SH-019).

---

## Scope

Files changed:

- `.github/workflows/ci-nightly.yml` (new, 33 lines). Copy of shepherd's template + an ccache cache step.

No changes to: Makefile (ci-nightly / smoke / programs all unchanged); existing CI workflow (ci.yml stays as PR gate on push/PR); no kernel-tree dependencies required.

---

## Design delta

Thin workflow that calls `make ci-nightly`. The Makefile already wraps `ci-nightly-body` with a failure-trap that opens a `needs-human` issue. The workflow adds one piece: ccache persistence between runs, which drops kernel build time ~6× when the key hits.

Not in scope for this story (deferred):
- `(ref, config, toolchain)` artifact cache for pre-built kernels (SH-024 §M2 scope extension; opens separately once the cron has a baseline of runs).
- Full defconfig / allmodconfig matrices (dev-cycle doc flagged these as "nightly can grow"; today's smoke is the first scheduled gate).

---

## Alternatives rejected

- **Keep the gate manual** — defeats "nightly catches regressions" purpose.
- **Use `smoke` alone (skip ci-nightly wrapper)** — loses the needs-human failure trap shipped in SH-019.
- **Pre-build kernels as GHA artifact cache** — valuable but larger-scope; defer to a follow-up SH after the simple workflow proves out.

---

## Breaking changes

None. New workflow; no existing behaviour changes.

---

## Testing strategy

- `yamllint .github/workflows/ci-nightly.yml` locally.
- Manual `gh workflow run ci-nightly.yml` after merge to validate the full path. First natural cron run: 2026-11-23 02:30 UTC.

---

## Testing commands

```sh
yamllint .github/workflows/ci-nightly.yml
# Post-merge:
gh workflow run ci-nightly.yml -R bb-claw/kernel-test --ref dev
```

---

## Rollout

Merge to `dev` → auto-promote to `main` on next release. First live cron fires at the next 02:30 UTC. If the build fails, `ci-nightly-body`'s wrapper opens a needs-human issue (already live from SH-019).
