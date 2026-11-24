# SH-056 — verify-index-status: plan

**Story**: Tracked in shepherd ([SH-056](https://github.com/bboortz/shepherd/blob/main/docs/stories/SH-056-verify-index-status.md))
**Branch**: `feat/SH-056-verify-index-status`
**Status**: in-progress

---

## Situation

Shepherd's SH-056 closes a doc-staleness gap: `verify-traceability` reads
`status:` from story frontmatter, but nothing cross-checks the `INDEX.md`
status column against it. On 2026-11-23 (shepherd PR #55) six shipped stories
still showed `draft`/`in-progress` in the INDEX. The new verifier
(`scripts/verify-index-status.sh`) parses each story's frontmatter and the
matching INDEX row and fails on any mismatch or missing row.

Kernel-test is part of the fleet SH-056 covers. The verifier is adopted
byte-identical and wired into the existing `check-docs` target (shipped in
SH-055) as a sibling of `verify-plan-docs`. Kernel-test's `docs/stories/`
currently contains only templates and a header-only `INDEX.md` (no KT-NNN
stories yet), so the verifier is a **guard-only install** today — it blocks
drift the moment the first KT-NNN story lands.

---

## Problems to solve

1. **INDEX.md ↔ frontmatter drift is undetectable at CI time.** Nothing in
   kernel-test today compares the two. A story shipped on `dev` with INDEX
   still saying `in-progress` would merge silently.
2. **Fleet-name drift.** Shepherd and the other fleet repos will all expose
   `verify-index-status` as part of `check-docs`. Kernel-test must match the
   convention so a human or agent can rely on the same muscle memory.
3. **Template filename convention mismatch.** The shared script excludes
   templates via the `_*.md` glob (matches shepherd's `_template.md`).
   Kernel-test's `story-template.md` lacks the underscore prefix and would
   be misclassified as a story. Fixed by renaming to `_story-template.md`,
   bringing kernel-test in line with shepherd's convention.

---

## Goals

1. `scripts/verify-index-status.sh` present, byte-identical to shepherd's
   (`cmp` returns 0).
2. `make check-docs` runs `verify-plan-docs` then `verify-index-status`.
3. `docs/stories/_story-template.md` (renamed from `story-template.md`) is
   correctly excluded by the script's `_*.md` guard.
4. Test `tests/ci/test-SH-056-verify-index-status.sh` enforces the wiring
   and the script's pass/fail contract.

---

## Scope

Files changed:
- `scripts/verify-index-status.sh` — **new**, byte-identical copy from
  shepherd `scripts/verify-index-status.sh`.
- `Makefile` — add `.PHONY` entry, `verify-index-status` target, extend
  `check-docs` prerequisites.
- `docs/stories/story-template.md` → `docs/stories/_story-template.md`
  — rename to match shepherd's `_*.md` template convention so the script's
  exclusion glob applies.
- `docs/stories/INDEX.md` — update the inline reference to the renamed
  template.
- `memory/project.md` — update the repo-layout inline reference.
- `tests/ci/test-docs-structure.sh` — update the two assertions that
  pinned the old template path.
- `tests/ci/test-SH-056-verify-index-status.sh` — **new**, mirrors the
  shape of `test-SH-055-check-docs.sh`.
- `docs/plans/SH-056-verify-index-status-plan.md` — this doc.

No changes to: the shepherd script contents (byte-identical constraint),
`.githooks/pre-push`, other verifier scripts, any kernel code.

---

## Non-goals

- Backfilling `docs/stories/` with KT-NNN story files. The verifier is
  installed as a guard; story backfill is a separate story when it comes.
- Refactoring the status-column parser in `verify-index-status.sh`. The
  script is a byte-identical fleet artefact.
- Mirroring shepherd's `_9-questions.md` file layout changes (already
  matches).

---

## Design decisions

### Rename `story-template.md` → `_story-template.md`

The shared `verify-index-status.sh` excludes templates via the `_*.md`
glob. Kernel-test's template lacked the underscore prefix and was
misclassified as a story (frontmatter `status: draft`, no INDEX row →
false positive). Renaming is the minimal fleet-consistency move:

- **Alternative 1 — fork the script** to add a kernel-test-specific
  exclusion. Rejected: violates the byte-identical fleet constraint.
- **Alternative 2 — add a dummy INDEX row for the template.** Rejected:
  pollutes INDEX.md with a non-story row.
- **Chosen** — rename the template. Costs two test assertions and three
  doc references, aligns kernel-test with shepherd's convention.

### Keep historical plan-doc references to `story-template.md` unchanged

`docs/plans/docs-story-traceability-plan.md` and
`docs/plans/docs-restructure-plan.md` reference the old name. These are
historical artefacts describing past state; rewriting them would misrepresent
history. Left as-is.

---

## Breaking changes

- [ ] None — strictly additive or internal.
- [x] Yes — describe:
  - **Template path change**: `docs/stories/story-template.md` →
    `docs/stories/_story-template.md`. Any external linker pointing at
    the old path (none known inside kernel-test outside historical plan
    docs) would need to update. Inside the repo all live references have
    been updated.

---

## Rollout

- [x] `README.md` updated — not required; no public make target or variable
      changed (the `check-docs` target name is preserved; only its body
      grew a prerequisite).
- [x] `memory/` files updated — `memory/project.md` layout block.
- [ ] `docs/CAPABILITIES.md` updated — no new CAP ids introduced by
      kernel-test's adoption; the shepherd-side CAP
      `dev-cycle.verify-index-status` is tracked upstream.
- [x] `docs/stories/INDEX.md` — inline reference updated. No row entry
      needed (SH-056 is a shepherd-side story; kernel-test adopts the
      artefact).

---

## Testing commands

```sh
make check-docs
# Expected: exit 0, both verify-plan-docs and verify-index-status pass.

./scripts/verify-index-status.sh
# Expected: "verify-index-status: ok (INDEX.md matches frontmatter for all stories)".

bash tests/ci/test-SH-056-verify-index-status.sh
# Expected: all scenarios pass.

bash tests/ci/test-docs-structure.sh
# Expected: all scenarios pass (template-rename references updated).
```

---

## Shipping evidence (fill at pre-ship audit)

### Lens 1 — Gherkin coverage

| Scenario | Test pointer | Status |
|---|---|---|
| Script byte-identical to shepherd | `tests/ci/test-SH-056-verify-index-status.sh` (cmp scenario) | ✅ |
| `check-docs` includes `verify-index-status` | `tests/ci/test-SH-056-verify-index-status.sh` (Makefile scenarios) | ✅ |
| Verifier passes on current repo | `tests/ci/test-SH-056-verify-index-status.sh` (live-run scenario) | ✅ |
| Verifier fails on injected drift | `tests/ci/test-SH-056-verify-index-status.sh` (fixture scenario) | ✅ |

### Lens 2 — Capability coverage

| CAP id | Test pointer | Status |
|---|---|---|
| `dev-cycle.verify-index-status` (shepherd-side) | shepherd `tests/ci/test-SH-056-*.sh` + kernel-test `tests/ci/test-SH-056-verify-index-status.sh` | ✅ |

### Lens 3 — Self-consistency

| Check | Status |
|---|---|
| Script is byte-identical to shepherd's (cmp exit 0) | ✅ |
| `make verify-traceability` passes | ✅ |
| `make check-docs` passes | ✅ |
| `memory/project.md` layout block updated | ✅ |
| Rename does not break `test-docs-structure.sh` | ✅ |
