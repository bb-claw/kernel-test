# Stories index

Stories follow the format `KT-NNN-<slug>.md`. See `_story-template.md` for the full
format and `_9-questions.md` for the clarification checklist.

A story only moves to `ready` once all 9 questions have concrete answers and at least
one capability id (§9) is named. Plan doc + branch are cut at `ready → in-progress`.

## Status legend

| Status | Meaning |
|---|---|
| `draft` | 9-question pass not yet complete |
| `ready` | All questions answered; waiting for capacity |
| `in-progress` | Branch cut; plan doc exists |
| `shipped` | Merged to main |

## Stories

Column order matches the shepherd-fleet convention (`| ID | Status | Slug | Title |`)
so `scripts/verify-index-status.sh` (SH-056) can diff frontmatter ↔ INDEX.

| ID | Status | Slug | Title |
|----|--------|------|-------|
| KT-001 | in-progress | toybox-revert-0814 | Revert Toybox pin to 0.8.14 (0.8.15 hangs VM tests) |
