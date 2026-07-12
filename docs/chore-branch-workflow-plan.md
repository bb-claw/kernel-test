# Branch Workflow Setup — Plan

Branch: `chore/branch-workflow`
Start date: 2026-07-12

---

## Situation

All development has happened directly on `main` with no branch discipline.
Commit messages follow an informal conventional-commit style but are not enforced.
There is no design document requirement, no PR gate, and no branch protection.

---

## Problems to Solve

1. **No gate on main** — accidental direct pushes can break the repo; no review checkpoint exists
2. **Commit format not enforced** — messages drift from conventional format; harder to read history
3. **No upfront scope definition** — work starts without a written plan; scope creep goes undetected
4. **In-repo memory files are stale** — BusyBox references, wrong test counts, wrong defaults

---

## Goals

1. `main` is protected: PRs required, force-push blocked, branch deletions blocked
2. Every commit is rejected by `commit-msg` hook if it does not follow `<type>[(<scope>)]: <desc>`
3. Every push on `feat/*` or `fix/*` is rejected unless `docs/<slug>-plan.md` exists
4. Every push warns/fails if any `memory/*.md` exceeds 150 lines
5. `docs/plan-template.md` available for new branches
6. All in-repo memory files reflect current state (Toybox, 21 tests, i386 full coverage)

---

## Scope

Files/components changed:
- `.githooks/commit-msg` — new hook: conventional commit enforcement
- `.github/PULL_REQUEST_TEMPLATE.md` — new: type checkbox, test-run checklist, Toybox pitfalls
- `.githooks/pre-push` — add design doc check (feat/fix) + memory file size check
- `docs/plan-template.md` — new: template to copy for each branch
- `docs/chore-branch-workflow-plan.md` — this file
- `CLAUDE.md` — new Branch workflow section; build.sh description updated
- `Makefile` — hooks message; stale BUILD_TIMEOUT comment
- `memory/code-quality.md` — add commit-msg hook, branch workflow, fix stale content
- `memory/project.md` — BusyBox → Toybox, i386 full tests, 16 → 21 tests, vm.status fields
- `memory/test-inventory.md` — add tests 150–190, fix stale slot/pattern, trim to ≤ 150 lines
- `memory/workflows.md` — BUILD_TIMEOUT 600 → 1200, fix stale i386 section
- `memory/MEMORY.md` — test count 16 → 21

No changes to: test scripts, lib scripts, config fragments, Makefile build logic

---

## Non-goals

- GitHub Actions CI — no runner infrastructure yet
- Auto-merge on CI pass — depends on CI
- Automated design doc generation — manual process by convention

---

## Design decisions

### Merge commits, not squash

Squash erases the branch's commit-by-commit history. For a test harness where individual
commits often fix specific Toybox sh bugs, the history is the debugging record.
Rebase rewrites SHAs and breaks `git bisect` across branches.
Merge commits preserve everything; the PR merge commit is the single integration point.

### 0 required approving reviews

This is a solo project. Requiring 1 review would block self-merges on every PR.
The quality gates (hooks, PR template checklist) provide the discipline without
needing a human gatekeeper.

### Design docs required on feat/* and fix/* only

`chore/*` (tooling), `docs/*` (docs-only), and `refactor/*` branches are narrow by
convention — enforcing a design doc would add friction without benefit.
`feat/*` and `fix/*` can grow in scope unexpectedly; the plan forces upfront scoping.

### 150-line limit for memory files

Files that grow past 150 lines are usually mixing concerns. The limit is a signal to
split or trim, not a hard architectural rule. `MEMORY.md` is excluded (it is an index).

---

## Testing strategy

- **commit-msg hook** — test manually with valid and invalid messages
- **pre-push design doc check** — test by pushing a feat/ branch with and without the doc
- **branch protection** — test by attempting a direct push to main
- **memory size check** — test by pushing with a file deliberately over 150 lines

---

## Testing commands

```sh
# 1. commit-msg rejects invalid format
echo "bad message" > /tmp/msg.txt
bash .githooks/commit-msg /tmp/msg.txt
# Expected: exit 1, [commit-msg] ERROR printed

# 2. commit-msg accepts valid format
echo "feat(190_scheduler): add CFS test" > /tmp/msg.txt
bash .githooks/commit-msg /tmp/msg.txt
# Expected: exit 0

# 3. Branch protection blocks direct push to main
git push origin HEAD:main
# Expected: error: GH006 Protected branch update failed

# 4. pre-push blocks feat/ branch without design doc
git checkout -b feat/no-plan-test
git commit --allow-empty -m "test: empty"
git push origin feat/no-plan-test
# Expected: [pre-push] FAIL: design doc missing: docs/no-plan-test-plan.md
```
