#!/bin/bash
# verify-plan-docs.sh — SH-055 fleet-wide drift check for kernel-test.
#
# Asserts that the CURRENT branch — if it's a feat/SH-NNN-* or fix/SH-NNN-*
# branch — has a matching plan doc at docs/plans/SH-NNN-*-plan.md. Mirrors
# the plan-doc rule in .githooks/pre-push so CI backs up the local hook.
#
# Rule mirrors pre-push section 4:
#   BRANCH=feat/<slug>  OR  fix/<slug>
#   SLUG="${BRANCH#*/}"
#   require docs/plans/${SLUG}-plan.md
#
# Non-feat/fix branches: no-op, exit 0.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)

# CI contexts (GitHub Actions on PR) run detached — fall back to the ref the
# runner sets when available, else try GITHUB_HEAD_REF (PR head), else noop.
if [[ -z "$BRANCH" || "$BRANCH" == "HEAD" ]]; then
    BRANCH="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
fi

case "$BRANCH" in
    feat/*|fix/*)
        SLUG="${BRANCH#*/}"
        PLAN="docs/plans/${SLUG}-plan.md"
        if [[ -f "$REPO_ROOT/$PLAN" ]]; then
            printf '[verify-plan-docs] ok: %s\n' "$PLAN"
            exit 0
        else
            printf '[verify-plan-docs] FAIL: design doc missing: %s\n' "$PLAN" >&2
            printf '[verify-plan-docs]       create from docs/plans/plan-template.md\n' >&2
            exit 1
        fi
        ;;
    *)
        printf '[verify-plan-docs] skip: branch %s is not feat/* or fix/* — no plan-doc required\n' "${BRANCH:-<detached>}"
        exit 0
        ;;
esac
