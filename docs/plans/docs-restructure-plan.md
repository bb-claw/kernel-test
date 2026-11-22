# docs/ restructure plan

## Goal

Split the flat `docs/` directory into three typed subdirectories so document
intent is clear at a glance and tooling (hooks, CI, templates) can enforce
the right conventions per type.

## Target layout

```
docs/
  plans/   <slug>-plan.md   — implementation plan for every feat/* and fix/* branch
  specs/   <slug>.md        — specifications, workflows, reference documents
  stories/ KT-NNN-slug.md   — user stories numbered sequentially from KT-001
```

## Changes

| Area | Change |
|---|---|
| `.githooks/pre-push` | check `docs/plans/<slug>-plan.md` |
| `scripts/ci-lint.sh` | glob `docs/plans/*.md` for design-doc check |
| `CLAUDE.md` | update path references |
| `memory/code-quality.md` | update step-2 instruction |
| `memory/project.md` | update directory structure |
| `memory/patch-workflow.md` | update `docs/specs/` paths |
| `README.md` | update directory listing |
| `.githooks/README.md` | update design-doc path |
| `tests/ci/test-vf2config.sh` | update hardcoded plan path |
| New templates | `docs/plans/plan-template.md`, `docs/specs/spec-template.md`, `docs/stories/story-template.md` |
| New CI test | `tests/ci/test-docs-structure.sh` |

## Non-goals

- No changes to document content — file moves only.
- No retroactive renaming of existing slugs.
