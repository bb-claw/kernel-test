# SH-029 — branching-convergence: plan

**Story**: Tracked in shepherd ([SH-029](https://github.com/bboortz/shepherd/blob/main/docs/stories/SH-029-fleet-branching-convergence.md))
**Branch**: `feat/SH-029-branching-convergence`
**Status**: in-progress

---

## Situation

Kernel-test already has a `dev` branch; the GitHub default branch is still `main`. Shepherd's SH-029 umbrella prescribes `default=dev` across the fleet. This PR adds the shared `ci-release-promote` Makefile target + `ci-release.yml` workflow; operator flips default branch post-merge.

---

## Problems to solve

1. `gh pr create` targets `main` by default; should target `dev`.
2. No shared FF-promote path for `dev → main` + tag. Shepherd's SH-029 defines one; kernel-test mirrors it.
3. Missing `VERSION` file — needed by `ci-release-promote` for tag naming.

---

## Goals

1. `make -n ci-release` resolves to `ci-release-promote` body.
2. `make -n ci-release-promote` on this feat branch exits 1 ("must run on 'dev'").
3. `VERSION` file exists at repo root, seeded to `0.1.0`.
4. `.github/workflows/ci-release.yml` dispatches on `dev`, SHA-pinned actions, 15-min cap.

---

## Scope

Files changed:

- `Makefile` — new `ci-release-promote` target (~15 lines); `ci-release` body depends on it.
- `.github/workflows/ci-release.yml` — new, 33 lines. Byte-identical to shepherd template.
- `VERSION` — new, `0.1.0`.

No changes to: existing `build` / `test` / `test-affected` / `smoke` / `programs` / `ci-test` / `lint` recipes; existing workflows besides adding one new file.

---

## Design delta

Kernel-test adopts the shepherd shared contract shape for `ci-release`. The existing nightly kernel-smoke suite (SH-024 scope) and framework self-tests continue unchanged.

---

## Alternatives rejected

- **Keep default=main** — contradicts the 2026-11-22 convergence decision.
- **Skip the VERSION file** — `ci-release-promote` asserts its presence; kernel-test needs one to use the shared promote path. 0.1.0 is a sensible starting point.
- **Inline FF logic in ci-release.yml workflow** — bypasses the shared Makefile pattern.

---

## Breaking changes

- `make ci-release` now MUTATES git state when run on `dev` (FF + tag + push). Previously printed a placeholder note. Safe on non-dev (exit 1).
- Post-merge: GitHub default branch flips to `dev`.

---

## Testing strategy

- `make -n ci-release` + `make -n ci-release-promote` locally.
- Post-merge: operator dispatches `ci-release.yml` once as a no-op smoke; verify `vX.Y.Z` tag + FF.

---

## Testing commands

```sh
make -n ci-release           # → ci-release-promote body
make -n ci-release-promote   # → shell assert; exits 1 on non-dev
cat VERSION                   # → 0.1.0
```

---

## Rollout

Merge to `main` (current default). Then:

```sh
gh repo edit bb-claw/kernel-test --default-branch dev
# verify dev + main rulesets
gh workflow run ci-release.yml -R bb-claw/kernel-test --ref dev   # smoke
```
