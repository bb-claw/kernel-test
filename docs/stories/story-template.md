---
id: KT-NNN
slug: short-kebab-slug
status: draft          # draft → ready → in-progress → shipped
created: YYYY-MM-DD
owner: "@<github-handle>"
branch: ""             # filled when status moves to in-progress
plan: ""               # filled when branch is cut
---

# KT-NNN — <one-line title>

One paragraph: who this is for, what changes for them, why now.

## 1. Who is the operator/user?

Role, mental state, what else they're doing. Be concrete — one sentence.

## 2. When does the story fire?

Trigger: event, state, or operator action that activates this story.

## 3. What does success look like?

Observable, operator-visible outcome. Must be mechanically checkable.

## 4. How urgent?

- [ ] Critical (correctness, regression, security)
- [ ] High (workflow blocker, significant quality loss)
- [ ] Normal (enhancement, new feature)
- [ ] Low (nice-to-have, polish)

## 5. Happy path

```
<Exact command the user runs. Include flags and expected output/exit code.>
```

## 6. Edge cases / failure modes

- <Case 1>
- <Case 2>

## 7. Out of scope

What could creep in but shouldn't. Explicit non-goals prevent plan-doc scope creep.

## 8. Acceptance criteria (Gherkin)

```gherkin
Scenario: <happy path name>
  Given <precondition>
  When  <action>
  Then  <observable outcome>
  And   <optional secondary outcome>

Scenario: <failure / edge case>
  Given <precondition>
  When  <action>
  Then  <outcome>
```

Each Scenario must have a pointer in the plan doc's Shipping evidence table.
Acceptance test lives at `tests/ci/test_KT_NNN_<slug>.sh`.

## 9. Capabilities delivered or extended

- NEW `<cap.id>` — one-line description
- EXT `<cap.id>` — what this story adds to the existing capability

New CAP ids go into `docs/CAPABILITIES.md` in the same PR.
`make verify-traceability` enforces the bidirectional link.

## References

- Plan: `docs/plans/KT-NNN-<slug>-plan.md`
- Acceptance test: `tests/ci/test_KT_NNN_<slug>.sh`
- Capabilities: `docs/CAPABILITIES.md`
