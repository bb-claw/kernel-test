#!/bin/bash
# Verify bidirectional traceability: story §9 CAP ids ↔ docs/CAPABILITIES.md ↔ test files.
#
# Checks:
#   T1 — Every CAP id referenced in a story's "## 9." section exists in CAPABILITIES.md
#   T2 — Every CAP in CAPABILITIES.md has a non-empty "Covered by:" pointer
#   T3 — Every "Covered by:" pointer in CAPABILITIES.md resolves to an existing file
#   T4 — Every story in INDEX.md exists as a file
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CAPS="$REPO/docs/CAPABILITIES.md"
STORIES_DIR="$REPO/docs/stories"
INDEX="$STORIES_DIR/INDEX.md"

rc=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; rc=1; }

# ── T1: CAP ids in story §9 exist in CAPABILITIES.md ─────────────────────────

printf '[traceability] T1: story CAP ids → CAPABILITIES.md\n'
while IFS= read -r story; do
    [[ $story == *_template* ]] && continue
    [[ $story == *_9-questions* ]] && continue
    # Extract cap ids from "## 9." section: lines like `- NEW \`cap.foo\`` or `- EXT \`cap.foo\``
    mapfile -t cap_ids < <(
        awk '/^## 9\./,/^## /' "$story" 2>/dev/null \
        | grep -oE '`[a-z][a-z0-9._-]+`' | tr -d '`' || true
    )
    for cap in "${cap_ids[@]}"; do
        if grep -q "^### $cap$" "$CAPS" 2>/dev/null; then
            pass "$(basename "$story"): CAP $cap in CAPABILITIES.md"
        else
            fail "$(basename "$story"): CAP $cap missing from CAPABILITIES.md"
        fi
    done
done < <(find "$STORIES_DIR" -maxdepth 1 -name 'KT-*.md' 2>/dev/null)

# ── T2: Every CAP in CAPABILITIES.md has a Covered by pointer ────────────────

printf '[traceability] T2: CAPABILITIES.md covered-by completeness\n'
# Only scan the "## Registry" section to skip format examples in the header.
mapfile -t cap_headers < <(
    awk '/^## Registry/,0' "$CAPS" 2>/dev/null | grep '^### ' | sed 's/^### //' || true
)
for cap in "${cap_headers[@]}"; do
    covered=$(awk "/^### $cap$/,/^###/" "$CAPS" | grep -m1 'Covered by:' | sed 's/.*Covered by:[[:space:]]*//' || true)
    if [[ -n $covered ]]; then
        pass "CAP $cap has Covered-by pointer"
    else
        fail "CAP $cap missing 'Covered by:' in CAPABILITIES.md"
    fi
done

# ── T3: Covered-by pointers resolve to existing files ────────────────────────

printf '[traceability] T3: Covered-by file pointers exist\n'
while IFS= read -r line; do
    # Extract backtick-quoted path: `tests/ci/test_KT_001_foo.sh`
    path=$(printf '%s' "$line" | grep -oE '`tests/[^`]+`' | tr -d '`' | head -1 || true)
    [[ -z $path ]] && continue
    if [[ -f "$REPO/$path" ]]; then
        pass "$path exists"
    else
        fail "Covered-by pointer broken: $path not found"
    fi
done < <(awk '/^## Registry/,0' "$CAPS" 2>/dev/null | grep 'Covered by:' || true)

# ── T4: INDEX.md rows resolve to story files ─────────────────────────────────

printf '[traceability] T4: INDEX.md entries → story files\n'
while IFS='|' read -r _ id slug _ _ _ _; do
    id=$(printf '%s' "$id" | tr -d ' ')
    slug=$(printf '%s' "$slug" | tr -d ' []')
    [[ $id =~ ^KT-[0-9]+ ]] || continue
    # Strip markdown link syntax: [slug](KT-NNN-slug.md) → KT-NNN-slug.md
    file=$(printf '%s' "$slug" | grep -oE 'KT-[0-9]+-[^)]+' || true)
    [[ -z $file ]] && file="${id}-*.md"
    matches=$(find "$STORIES_DIR" -maxdepth 1 -name "${file}" 2>/dev/null | wc -l)
    if [[ $matches -gt 0 ]]; then
        pass "INDEX entry $id → story file found"
    else
        fail "INDEX entry $id → no matching story file (expected $file)"
    fi
done < <(grep '|' "$INDEX" 2>/dev/null | grep 'KT-' || true)

# ── Result ────────────────────────────────────────────────────────────────────

if [[ $rc -eq 0 ]]; then
    printf '[traceability] all checks passed\n'
else
    printf '[traceability] FAIL — fix the issues above\n'
fi
exit $rc
