#!/bin/bash
# Context-size enforcement: CLAUDE.md ≤ 150 lines, memory/*.md ≤ 150 lines.
# Keeps AI context windows lean; called from make lint-context, ci-lint.sh, pre-push.
# REPO_ROOT can be overridden for testing.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
rc=0

ok()   { printf '[lint-context] ok:   %s\n' "$*"; }
fail() { printf '[lint-context] FAIL: %s\n' "$*"; rc=1; }

# ── CLAUDE.md ≤ 150 lines ─────────────────────────────────────────────────────

claude_lines=$(wc -l < "$REPO_ROOT/CLAUDE.md" 2>/dev/null || echo 0)
if [[ $claude_lines -le 150 ]]; then
    ok "CLAUDE.md ($claude_lines / 150 lines)"
else
    fail "CLAUDE.md too long: $claude_lines lines (limit 150) — move detail to memory/*.md"
fi

# ── memory/*.md ≤ 150 lines (MEMORY.md index is exempt) ──────────────────────

while IFS= read -r f; do
    lines=$(wc -l < "$f")
    name="${f#$REPO_ROOT/}"
    if [[ $lines -le 150 ]]; then
        ok "$name ($lines / 150 lines)"
    else
        fail "$name too long: $lines lines (limit 150) — split or trim"
    fi
done < <(find "$REPO_ROOT/memory" -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | sort)

exit $rc
