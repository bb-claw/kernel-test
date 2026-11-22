# KT-NNN — <slug>: plan

**Story**: [`docs/stories/KT-NNN-<slug>.md`](../stories/KT-NNN-<slug>.md)
**Branch**: `feat/KT-NNN-<slug>`
**Status**: in-progress  # in-progress → shipped

---

## Situation

What the current state is and why this work is needed. 2–4 sentences.

---

## Problems to solve

1. **<Problem>** — what is broken or missing and what impact it has
2. ...

---

## Goals

One-to-one with the Gherkin Scenarios in the story.

1. <Concrete, verifiable outcome>
2. ...

---

## Scope

Files / components changed:
- `<file>` — what changes and why
- *(or "none — docs/CI only")*

No changes to: <list anything adjacent that might seem in scope but isn't>

---

## Non-goals

- <What is explicitly out of scope — with a brief reason>

---

## Design decisions

### <Decision>

Option chosen and why. Alternatives rejected in one line each.

---

## Breaking changes

- [ ] None — strictly additive or internal.
- [ ] Yes — describe:
  - **CLI / make target changes**: flag removed/renamed, variable default changed
  - **Output format changes**: report shape, status file fields
  - **Behaviour semantics**: what callers depended on that now works differently

If yes, `README.md` and affected memory files must be updated in the same PR.

---

## Rollout

- [ ] `README.md` updated (if public make target or variable changed)
- [ ] `memory/` files updated (project.md, workflows.md, code-quality.md as applicable)
- [ ] `docs/CAPABILITIES.md` updated (if story §9 names new CAP ids)
- [ ] `docs/stories/INDEX.md` row updated to `shipped`

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, ≥70% decision paths

make ci-test
# Expected: all tests pass
```

---

## Shipping evidence (fill at pre-ship audit)

A story only moves to `shipped` when every row has a non-empty evidence pointer.
Any ⚠️ / ❌ row blocks shipping — cycle back to implementation.

### Lens 1 — Gherkin coverage

| Scenario (from story §8) | Test pointer | Status |
|---|---|---|
| <Scenario name> | `tests/ci/test_KT_NNN_<slug>.sh:LN` | ❌ |

### Lens 2 — Capability coverage

| CAP id (from story §9) | Test pointer | Status |
|---|---|---|
| `<cap.id>` | `tests/ci/test_KT_NNN_<slug>.sh:LN` + `docs/CAPABILITIES.md#<cap.id>` | ❌ |

### Lens 3 — Self-consistency

| Check | Status |
|---|---|
| Story §7 (out-of-scope) not violated | ❌ |
| New CAPs from story §9 all appear in `docs/CAPABILITIES.md` | ❌ |
| `make verify-traceability` passes | ❌ |
| `make dev-test` passes | ❌ |
| `memory/` files updated where applicable | ❌ |
