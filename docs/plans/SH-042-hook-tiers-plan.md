# SH-042 — hook-tiers: plan

**Story**: Tracked in shepherd ([SH-042](https://github.com/bboortz/shepherd/blob/main/docs/stories/SH-042-hook-tiers.md))
**Branch**: `feat/SH-042-hook-tiers`
**Status**: in-progress

---

## Situation

Shepherd's SH-042 ships two canonical fleet-tier Makefile wrappers so every
managed repo exposes the same names at the git-hook boundary. Kernel-test is
one of the fleet repos covered by the Layer 3 mapping. The tier names are
fleet-uniform; each repo keeps its NATIVE step names inside repo-local
`COMMIT_STEPS` / `PUSH_STEPS` variables.

---

## Problems to solve

1. **No uniform commit-stage hook across the fleet** — shepherd's verifier and
   any human arriving from another fleet repo cannot `make hook-commit`
   without first learning this repo's bespoke target names.
2. **No uniform push-stage hook across the fleet** — same problem at push
   time; repos used to wire their own `pre-push` logic by hand.
3. **No fast commit-stage shell lint** — the existing `lint` target
   shellchecks all 92 bash + 52 POSIX-sh files and is already wired into the
   push tier; it is too heavy for the ~15 s commit-stage budget.

---

## Goals

1. `make -n hook-commit` and `make -n hook-push` resolve cleanly on a clean
   checkout.
2. `hook-commit` invokes `shellcheck-staged` only — stays within ~15 s.
3. `hook-push` invokes `lint` + `ci-test` — stays within ~2 min.
4. `shellcheck-staged` no-ops with a clear skip marker when no `*.sh` is
   staged, so empty / docs-only commits never spend wall time here.
5. Fleet acceptance test `tests/ci/test-SH-042-hook-tiers.sh` is green.

---

## Scope

Files changed:

- `Makefile` — add two tier wrappers, one new step target, extend `.PHONY`,
  add two help lines. One new target only: `shellcheck-staged`.
- `tests/ci/test-SH-042-hook-tiers.sh` — new, 9 assertions.
- `VERSION` — bumped `0.1.1 → 0.1.2`.

No changes to: existing `lint` / `lint-context` / `ci` / `ci-test` recipes;
any step-level target renames; workflows; `.shepherd.yml`.

---

## Design decisions

### Fleet-uniform tier names, repo-native step names

`COMMIT_STEPS = shellcheck-staged`, `PUSH_STEPS = lint ci-test`. Matches
shepherd Layer 3 (v3). Each repo keeps its own vocabulary inside the
variables; only the two wrapper names are fleet-wide.

### `shellcheck-staged` is scoped to the diff

Running `shellcheck` across all 144 shell files would blow the commit-stage
~15 s budget. The staged-only variant scales with the diff and is a no-op
on empty / docs-only commits (`git diff --cached --name-only
--diff-filter=ACM | grep '\.sh$'` → empty).

---

## Alternatives rejected

- **Alias `hook-commit` → `lint`.** Lint is the push-stage gate; running all
  of it per commit would exceed the ~15 s budget (currently ~15-20 s total).
- **Add `shellcheck-staged` to `.githooks/pre-commit` directly** — bypasses
  the Makefile contract and makes the behaviour invisible to shepherd's
  verifier.

---

## Breaking changes

- [x] None — strictly additive. Existing `lint` / `ci-test` targets unchanged;
  no `.githooks/*` edits; no workflow edits.

---

## Rollout

- [x] `README.md` — not updated; public pipeline surface unchanged.
- [x] Help text — two `help:` lines added for `hook-commit` / `hook-push`.
- [x] `memory/` — no update needed; the two new wrappers are dev-cycle hooks,
  not new dev-cycle surface.

---

## Testing commands

```sh
make -n hook-commit        # must resolve, no errors
make -n hook-push          # must resolve, no errors
make hook-commit           # must no-op with skip marker when nothing staged
tests/ci/test-SH-042-hook-tiers.sh   # must print "9 passed, 0 failed"
make ci-test               # must pass (50 → 51 tests incl. new SH-042)
```

Observed wall time locally: `make hook-push` = ~1 min 32 s against the
~2 min budget.

---

## Shipping evidence (filled at pre-ship audit)

### Lens 1 — Gherkin coverage

| Scenario (fleet-wide intent) | Test pointer | Status |
|---|---|---|
| `make -n hook-commit` / `hook-push` resolve cleanly | `tests/ci/test-SH-042-hook-tiers.sh` scenarios 1-2 | ok |
| hook-commit expands to shellcheck-staged | `tests/ci/test-SH-042-hook-tiers.sh` scenario 3 | ok |
| hook-push expands to lint + ci-test | `tests/ci/test-SH-042-hook-tiers.sh` scenario 4 | ok |
| shellcheck-staged no-ops with nothing staged | `tests/ci/test-SH-042-hook-tiers.sh` scenario 5 | ok |

### Lens 2 — Capability coverage

| CAP id | Test pointer | Status |
|---|---|---|
| `dev-cycle.tier.hook-commit` | `tests/ci/test-SH-042-hook-tiers.sh` | ok (registered in shepherd) |
| `dev-cycle.tier.hook-push` | `tests/ci/test-SH-042-hook-tiers.sh` | ok (registered in shepherd) |

### Lens 3 — Self-consistency

| Check | Status |
|---|---|
| No workflow / `.shepherd.yml` edits | ok |
| Only one new step target (`shellcheck-staged`) | ok |
| `make ci-test` passes (51 tests) | ok |
| `make hook-push` within ~2 min budget | ok (~1 min 32 s) |
