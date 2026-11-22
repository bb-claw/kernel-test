#!/bin/bash
# Tests for docs/ directory structure: plans/, specs/, stories/ subdirectories,
# templates present, hook enforces docs/plans/<slug>-plan.md path, and all
# cross-file doc references resolve to files that actually exist.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Subdirectory existence ────────────────────────────────────────────────────

begin_test "docs/plans/ directory exists"
assert_dir_exists "$REPO/docs/plans" "docs/plans/ present"

begin_test "docs/specs/ directory exists"
assert_dir_exists "$REPO/docs/specs" "docs/specs/ present"

begin_test "docs/stories/ directory exists"
assert_dir_exists "$REPO/docs/stories" "docs/stories/ present"

# ── Templates present ─────────────────────────────────────────────────────────

begin_test "docs/plans/plan-template.md present"
assert_file_exists "$REPO/docs/plans/plan-template.md" "plan-template.md in docs/plans/"

begin_test "docs/specs/spec-template.md present"
assert_file_exists "$REPO/docs/specs/spec-template.md" "spec-template.md in docs/specs/"

begin_test "docs/stories/story-template.md present"
assert_file_exists "$REPO/docs/stories/story-template.md" "story-template.md in docs/stories/"

# ── No plan files remain at docs/ root ───────────────────────────────────────

begin_test "no *-plan.md files at docs/ root"
stray=$(find "$REPO/docs" -maxdepth 1 -name '*-plan.md' 2>/dev/null || true)
if [[ -z $stray ]]; then
    pass "no plan files at docs/ root"
else
    fail "plan files found at docs/ root (should be in docs/plans/): $stray"
fi

# ── No workflow/spec files remain at docs/ root ───────────────────────────────

begin_test "no *-workflow.md files at docs/ root"
stray=$(find "$REPO/docs" -maxdepth 1 -name '*-workflow.md' 2>/dev/null || true)
if [[ -z $stray ]]; then
    pass "no workflow files at docs/ root"
else
    fail "workflow files found at docs/ root (should be in docs/specs/): $stray"
fi

# ── Hook enforces docs/plans/ path ───────────────────────────────────────────

begin_test "pre-push hook checks docs/plans/<slug>-plan.md"
hook="$REPO/.githooks/pre-push"
assert_file_exists "$hook" "pre-push hook present"
hook_content=$(cat "$hook")
assert_contains "$hook_content" "docs/plans/\${SLUG}-plan.md" "hook references docs/plans/ path"
assert_not_contains "$hook_content" '"docs/${SLUG}-plan.md"' "hook does not use old docs/ root path"

# ── ci-lint.sh checks docs/plans/ ────────────────────────────────────────────

begin_test "ci-lint.sh checks docs/plans/*.md"
lint="$REPO/scripts/ci-lint.sh"
assert_file_exists "$lint" "ci-lint.sh present"
lint_content=$(cat "$lint")
assert_contains "$lint_content" "docs/plans/*.md" "ci-lint globs docs/plans/"

# ── Story template has KT-NNN format ─────────────────────────────────────────

begin_test "story-template.md uses KT-NNN format"
tmpl=$(cat "$REPO/docs/stories/story-template.md")
assert_contains "$tmpl" "KT-NNN" "story template has KT-NNN prefix"

# ── Cross-file reference stability ───────────────────────────────────────────
# Every file in the repo that hard-codes a docs/ path must point to a file
# that actually exists after the restructure.

begin_test "docs refs in scripts/valgrind.sh resolve"
assert_file_exists "$REPO/docs/plans/programs-build-unification-plan.md" \
    "docs/plans/programs-build-unification-plan.md (referenced by valgrind.sh)"

begin_test "docs refs in scripts/init-data-repo.sh resolve"
assert_file_exists "$REPO/docs/plans/data-repo-plan.md" \
    "docs/plans/data-repo-plan.md (referenced by init-data-repo.sh)"

begin_test "docs refs in memory/patch-workflow.md resolve"
assert_file_exists "$REPO/docs/specs/patch-quality-workflow.md" \
    "docs/specs/patch-quality-workflow.md (referenced by memory/patch-workflow.md)"
assert_file_exists "$REPO/docs/specs/upstream-patch-workflow.md" \
    "docs/specs/upstream-patch-workflow.md (referenced by memory/patch-workflow.md)"

begin_test "docs refs in tests/ci/test-vf2config.sh resolve"
assert_file_exists "$REPO/docs/plans/visionfive2-config-plan.md" \
    "docs/plans/visionfive2-config-plan.md (referenced by test-vf2config.sh)"

# ── No stale docs/ root references in scripts ────────────────────────────────

begin_test "no stale docs/ root plan references in scripts"
stale=$(grep -rn "docs/[a-z].*-plan\.md" \
    "$REPO/scripts" "$REPO/.githooks" "$REPO/memory" "$REPO/CLAUDE.md" "$REPO/README.md" \
    2>/dev/null | grep -v "docs/plans/" | grep -v "docs/stories/" | grep -v "docs/specs/" || true)
if [[ -z $stale ]]; then
    pass "no stale docs/ root plan references in scripts/hooks/memory"
else
    fail "stale references to docs/ root found (should be docs/plans/ or docs/specs/):"$'\n'"$stale"
fi

begin_test "no stale docs/ root workflow references in scripts"
stale=$(grep -rn "docs/[a-z].*-workflow\.md" \
    "$REPO/scripts" "$REPO/.githooks" "$REPO/memory" "$REPO/CLAUDE.md" "$REPO/README.md" \
    2>/dev/null | grep -v "docs/specs/" || true)
if [[ -z $stale ]]; then
    pass "no stale docs/ root workflow references"
else
    fail "stale references to docs/ root workflow files found:"$'\n'"$stale"
fi

finish
