# SH-055 — check-docs: plan

**Story**: Tracked in shepherd ([SH-055](https://github.com/bboortz/shepherd/blob/main/docs/stories/SH-055-check-docs.md))
**Branch**: `feat/SH-055-check-docs`
**Status**: in-progress

---

## Situation

Shepherd's SH-055 unifies the fleet's doc-drift entry point under one target
name: `make check-docs`. Each repo already enforces some kind of doc trail
(story → plan → code), but every repo uses a different target name, so a human
or agent arriving from another fleet repo cannot rely on muscle memory.
Kernel-test is one of the seven fleet repos covered by the per-repo mapping
in the story (§3 table). Shepherd ships as the reference in PR #58; this PR
is the kernel-test adoption.

Kernel-test already enforces the plan-doc rule locally through
`.githooks/pre-push` section 4: every `feat/*` or `fix/*` branch must have
`docs/plans/<slug>-plan.md` before a push. The local hook is bypassable
(`git push --no-verify`), and CI has no Makefile-level equivalent — so a
bypassed push lands on `dev` without the design-doc gate. SH-055 closes that
gap by exposing the invariant through a Makefile target wired into `hook-push`
and `ci-branch`, matching the fleet-wide convention.

---

## Problems to solve

1. **No Makefile-level plan-doc drift check** — the rule lives only in
   `.githooks/pre-push`. `git push --no-verify` bypasses it; CI has no
   equivalent enforcement. A dropped plan doc can land on `dev`.
2. **Fleet-name drift** — every other fleet repo will expose `make check-docs`
   after SH-055. Kernel-test must match the convention so the agent and any
   human can use one command across the fleet.
3. **Hook/CI symmetry** — the local pre-push rule is not backed up at CI
   time. Belt-and-braces (story §6: "Author pays the push cost once; CI backs
   it up if the hook was bypassed.") requires both.

---

## Goals

One-to-one with the Gherkin Scenarios in shepherd's SH-055 story §8:

1. `.PHONY: check-docs verify-plan-docs` declared; targets resolve under
   `make -n`.
2. `check-docs` body is `verify-plan-docs` (kernel-test's per-repo mapping
   per the story §3 table).
3. `PUSH_STEPS` and `ci-branch` both include `check-docs`.
4. On a feat/* branch WITH the matching plan doc, `make check-docs` exits 0.
5. On a feat/* branch WITHOUT the matching plan doc, `make check-docs` exits
   non-zero and names the expected plan path.
6. On a non-feat/non-fix branch (e.g. `main`, `dev`, `docs/*`,
   `refactor/*`, `chore/*`), `make check-docs` is a clean no-op.
7. Fleet acceptance test `tests/ci/test-SH-055-check-docs.sh` is green.

---

## Scope

Files changed:
- `scripts/verify-plan-docs.sh` — new, 1 tiny verifier (~40 lines).
  Mirrors the plan-doc rule in `.githooks/pre-push` section 4.
- `Makefile` — add `verify-plan-docs` + `check-docs` targets;
  extend `.PHONY`; add `check-docs` to `PUSH_STEPS` (SH-042 variable) and
  `ci-branch` prerequisites.
- `tests/ci/test-SH-055-check-docs.sh` — new acceptance test, mirrors
  `test-SH-042-hook-tiers.sh` shape.
- `docs/plans/SH-055-check-docs-plan.md` — this doc.
- `VERSION` — bumped per repo convention.

No changes to: the pre-push hook itself (rule stays authoritative there;
verify-plan-docs.sh just replicates it so the Makefile can call it too).

---

## Non-goals

- **No new drift checks.** SH-055 unifies the entry point, it does not
  invent new validation. Story §7.
- **No logic in verify-plan-docs.sh beyond mirroring pre-push section 4.**
  The two checkers must stay synchronised; the Makefile wrapper is thin.
- **No `hook-commit` wiring.** Story §7 explicitly rejects running check-docs
  from the ~15 s commit-stage budget. `hook-push`'s ~2 min is the right stage.

---

## Design decisions

### `verify-plan-docs.sh` mirrors pre-push section 4 verbatim

The pre-push hook is the authoritative definition of the rule. The Makefile
verifier must follow the same case `feat/*|fix/*` branch-name regex and the
same `docs/plans/<slug>-plan.md` path shape. Any future change to the rule
updates both sites. Rejected: generic "walk every shipped story" variant —
kernel-test has no shipped-story-list concept (docs/stories/ is sparse; SH
IDs live in shepherd).

### Added to `PUSH_STEPS` AND `ci-branch` (not just one)

Per story §6: "CI runs `check-docs` twice (hook-push + ci-branch).
Intentional belt-and-braces." The hook is bypassable; CI is not. Both
must gate.

### `check-docs` on non-feat/non-fix branches: no-op, exit 0

Matches pre-push section 4 behaviour exactly. Running `make check-docs` on
`main` or `dev` prints a skip marker and returns success. Prevents
`ci-branch` from failing on branches without an SH-NNN scope.

---

## Breaking changes

- [x] None — strictly additive. New Makefile targets, new script. Existing
  `hook-push` and `ci-branch` callers see one extra prerequisite that
  no-ops on branches without a plan-doc requirement.

---

## Rollout

- [x] `Makefile` extended with `check-docs` + `verify-plan-docs` + `.PHONY`
  update + `PUSH_STEPS` + `ci-branch` wiring.
- [x] `scripts/verify-plan-docs.sh` added, executable, shellcheck-clean.
- [x] `tests/ci/test-SH-055-check-docs.sh` added as acceptance test.
- [x] `VERSION` bumped per repo convention.
- [ ] Shepherd `docs/stories/INDEX.md` updated to `shipped` after merge.

---

## Testing commands

```sh
make -n check-docs
# Expected: `bash scripts/verify-plan-docs.sh`

make check-docs
# Expected on this branch: [verify-plan-docs] ok: docs/plans/SH-055-check-docs-plan.md

bash tests/ci/test-SH-055-check-docs.sh
# Expected: all scenarios pass, exit 0
```
