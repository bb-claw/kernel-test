# docs-story-traceability plan

**Story**: n/a (bootstrap)
**Branch**: `feat/docs-story-traceability`

## Design delta

Adopt the Design-Driven, Test-Guarded (DD-TGD) story format from forge/beaconry/healthy.

New artefacts:
- `docs/stories/story-template.md` — full 9-question + Gherkin + CAP format
- `docs/stories/_9-questions.md` — canonical question set reference
- `docs/stories/INDEX.md` — running story register
- `docs/CAPABILITIES.md` — bidirectional capability registry
- `docs/plans/plan-template.md` — updated with story backlink and 3-lens Shipping evidence
- `scripts/verify-traceability.sh` — enforcement script
- `make verify-traceability` — Makefile target

Traceability chain: Story §9 (CAP ids) → `docs/CAPABILITIES.md` → test file pointer.
Shipping evidence enforces that every Gherkin scenario resolves to a test file line before
a story moves to `shipped`.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| Single merged evidence table (Forge style) | Healthy's 3-lens split (Gherkin/Behaviour/Self-consistency) is clearer for a test harness project where the three concerns are genuinely different |
| Beaconry's 8-question variant | Kernel-test stories are user-operator stories, same as Healthy — full 9 questions fit better |

## Breaking changes

None — all additive. Existing `story-template.md` is replaced; no existing stories use it yet.

## Rollout

- [ ] `make verify-traceability` added to `make lint` chain
- [ ] CI test `test-docs-structure.sh` updated with format guards
- [ ] `memory/code-quality.md` updated (branch creation step 2)
- [ ] `CLAUDE.md` updated (new make target, story format note)

## Shipping evidence

| Scenario | Evidence | Status |
|---|---|---|
| story-template has 9 sections | `tests/ci/test-docs-structure.sh` | ✅ |
| INDEX.md and CAPABILITIES.md exist | `tests/ci/test-docs-structure.sh` | ✅ |
| verify-traceability passes on empty registry | `make verify-traceability` | ✅ |
| stale root references guarded | `tests/ci/test-docs-structure.sh` | ✅ |
