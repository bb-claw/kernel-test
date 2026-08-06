#!/bin/bash
# Tier 1 static checks — run via: make lint
# All checks run even when one fails (reports all problems in one pass).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rc=0

ok()   { printf '[lint] ok:   %s\n' "$*"; }
fail() { printf '[lint] FAIL: %s\n' "$*"; rc=1; }
info() { printf '[lint] %s\n' "$*"; }
skip() { printf '[lint] skip: %s\n' "$*"; }

# All tracked .sh files
mapfile -t ALL_SH < <(git -C "$REPO_ROOT" ls-files '*.sh')
# VM test scripts (Toybox POSIX target)
mapfile -t TEST_SH < <(git -C "$REPO_ROOT" ls-files 'tests/custom/*.sh' 'tests/001_smoke.sh')
# Harness scripts (bash target) — everything except Toybox test scripts
mapfile -t HARNESS_SH < <(
    git -C "$REPO_ROOT" ls-files '*.sh' \
        | grep -v '^tests/custom/' \
        | grep -v '^tests/001_smoke\.sh$' \
        || true
)

# ── 1. bash -n syntax check (all .sh) ────────────────────────────────────────

info "bash -n syntax check (${#ALL_SH[@]} files) ..."
syntax_errors=()
for f in "${ALL_SH[@]}"; do
    bash -n "$REPO_ROOT/$f" 2>/dev/null || syntax_errors+=("$f")
done
if [[ ${#syntax_errors[@]} -eq 0 ]]; then
    ok "bash -n (${#ALL_SH[@]} files)"
else
    for f in "${syntax_errors[@]}"; do
        fail "bash -n: $f"
    done
fi

# ── 2. shellcheck on harness scripts (bash mode) ─────────────────────────────

if ! command -v shellcheck &>/dev/null; then
    skip "shellcheck not installed — run: make bootstrap"
else
    info "shellcheck bash mode (${#HARNESS_SH[@]} files) ..."
    abs_harness=("${HARNESS_SH[@]/#/$REPO_ROOT/}")
    if shellcheck --severity=warning "${abs_harness[@]}" 2>&1; then
        ok "shellcheck bash mode"
    else
        fail "shellcheck bash mode: issues found"
    fi

    # ── 3. shellcheck on Toybox test scripts (POSIX sh mode) ─────────────────

    if [[ ${#TEST_SH[@]} -gt 0 ]]; then
        info "shellcheck --shell=sh (${#TEST_SH[@]} Toybox test scripts) ..."
        abs_tests=("${TEST_SH[@]/#/$REPO_ROOT/}")
        if shellcheck --shell=sh --severity=warning "${abs_tests[@]}" 2>&1; then
            ok "shellcheck --shell=sh"
        else
            fail "shellcheck --shell=sh: issues in Toybox test scripts"
        fi
    fi
fi

# ── 4. context size enforcement (CLAUDE.md + memory/*.md) ────────────────────

info "context size enforcement ..."
bash "$REPO_ROOT/scripts/lint-context.sh" || rc=1

# ── 5. test-inventory coverage ────────────────────────────────────────────────

info "test-inventory coverage ..."
INVENTORY="$REPO_ROOT/memory/test-inventory.md"
mapfile -t CUSTOM_TESTS < <(git -C "$REPO_ROOT" ls-files 'tests/custom/*.sh' 'tests/001_smoke.sh')
inv_errors=()
for f in "${CUSTOM_TESTS[@]}"; do
    name=$(basename "$f" .sh)
    grep -q "$name" "$INVENTORY" 2>/dev/null || inv_errors+=("$(basename "$f")")
done
if [[ ${#inv_errors[@]} -eq 0 ]]; then
    ok "test-inventory coverage (${#CUSTOM_TESTS[@]} tests)"
else
    for t in "${inv_errors[@]}"; do
        fail "test-inventory missing: $t"
    done
fi

# ── 6. design doc check (feat/* and fix/* branches only) ─────────────────────

BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')
case "$BRANCH" in feat/*|fix/*)
    info "design doc check (branch: $BRANCH) ..."
    mapfile -t DOC_FILES < <(git -C "$REPO_ROOT" ls-files 'docs/*.md')
    if [[ ${#DOC_FILES[@]} -gt 0 ]]; then
        ok "design doc present (${#DOC_FILES[@]} file(s) in docs/)"
    else
        fail "no docs/*.md found — feat/* and fix/* branches require a design doc"
    fi
    ;;
esac

# ── 7. PR title format (CI only — requires GITHUB_EVENT_PATH) ────────────────

if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
    pr_title=$(python3 -c "
import json,sys
e=json.load(open('${GITHUB_EVENT_PATH}'))
print(e.get('pull_request',{}).get('title',''))
" 2>/dev/null || true)
    if [[ -z "$pr_title" ]]; then
        skip "PR title check: not a pull_request event"
    else
        # Conventional commit: type[(scope)]: description
        if printf '%s' "$pr_title" | grep -qE \
            '^(feat|fix|docs|refactor|chore|ci|test|style|perf)(\([^)]+\))?: .+'; then
            ok "PR title format: $pr_title"
        else
            fail "PR title does not follow conventional commit format: $pr_title"
        fi
    fi
fi

# ── Result ────────────────────────────────────────────────────────────────────

if [[ $rc -eq 0 ]]; then
    printf '[lint] all checks passed\n'
else
    printf '[lint] FAILED — fix the issues above\n'
fi
exit $rc
