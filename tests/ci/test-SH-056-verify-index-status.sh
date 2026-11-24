#!/bin/bash
# SH-056 — INDEX.md ↔ frontmatter status-drift verifier (kernel-test adoption).
#
# CAPs: dev-cycle.verify-index-status (shepherd-side), dev-cycle.tier.check-docs
#
# The script is byte-identical to shepherd's and is wired into check-docs as a
# sibling of verify-plan-docs. See docs/plans/SH-056-verify-index-status-plan.md.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Scenario 1 — script present and executable ──────────────────────────────
begin_test "scripts/verify-index-status.sh present and executable"
assert_file_exists "$REPO/scripts/verify-index-status.sh" "verify-index-status.sh present"
if [[ -x "$REPO/scripts/verify-index-status.sh" ]]; then
    pass "verify-index-status.sh executable"
else
    fail "verify-index-status.sh not executable"
fi

# ── Scenario 2 — Makefile declares target .PHONY ────────────────────────────
begin_test "verify-index-status is .PHONY and declared"
phony=$(awk '/^\.PHONY:/{flag=1} flag{printf "%s ", $0; if ($0 !~ /\\$/) {print ""; flag=0}}' "$REPO/Makefile")
assert_contains "$phony" "verify-index-status" ".PHONY includes verify-index-status"
mk=$(cat "$REPO/Makefile")
assert_contains "$mk" "verify-index-status:" "Makefile defines verify-index-status target"

# ── Scenario 3 — check-docs includes verify-index-status prerequisite ───────
begin_test "check-docs depends on verify-index-status"
out=$(make -C "$REPO" -n check-docs 2>&1)
assert_contains "$out" "verify-plan-docs.sh"      "check-docs dry-run invokes verify-plan-docs.sh"
assert_contains "$out" "verify-index-status.sh"   "check-docs dry-run invokes verify-index-status.sh"

# ── Scenario 4 — hook-push and ci-branch inherit via check-docs ─────────────
begin_test "hook-push and ci-branch dry-runs invoke verify-index-status"
out=$(make -C "$REPO" -n hook-push 2>&1)
assert_contains "$out" "verify-index-status.sh" "hook-push expands PUSH_STEPS to include verify-index-status"
out=$(make -C "$REPO" -n ci-branch 2>&1)
assert_contains "$out" "verify-index-status.sh" "ci-branch prereqs include verify-index-status"

# ── Scenario 5 — verify-index-status passes on current repo ─────────────────
begin_test "verify-index-status passes on current kernel-test state"
out=$("$REPO/scripts/verify-index-status.sh" 2>&1) \
    || fail "verify-index-status exited non-zero on current repo (output: $out)"
assert_contains "$out" "ok" "verifier reports ok on current repo"

# ── Scenario 6 — verify-index-status FAILS on injected frontmatter drift ────
# Build a minimal throwaway repo with one story whose frontmatter status does
# not match its INDEX row. The verifier must exit non-zero and name the mismatch.
begin_test "verify-index-status fails when frontmatter disagrees with INDEX"
tmpdir
work="$_LAST_TMPDIR"
mkdir -p "$work/scripts" "$work/docs/stories"
cp "$REPO/scripts/verify-index-status.sh" "$work/scripts/verify-index-status.sh"
chmod +x "$work/scripts/verify-index-status.sh"
cat > "$work/docs/stories/INDEX.md" <<'EOF'
# Stories index
## Stories
| ID | Status | Slug | Title |
|----|--------|------|-------|
| KT-001 | draft | fake-slug | Fake story |
EOF
cat > "$work/docs/stories/KT-001-fake-slug.md" <<'EOF'
---
id: KT-001
slug: fake-slug
status: shipped
---
# fake
EOF
out=$("$work/scripts/verify-index-status.sh" 2>&1) \
    && fail "verify-index-status unexpectedly exited 0 on injected drift"
assert_contains "$out" "KT-001" "verifier names the drifting story id"
assert_contains "$out" "shipped" "verifier names the frontmatter status"
assert_contains "$out" "draft"   "verifier names the INDEX status"

# ── Scenario 7 — verify-index-status FAILS when INDEX row is missing ────────
begin_test "verify-index-status fails when INDEX row missing for a story"
tmpdir
work="$_LAST_TMPDIR"
mkdir -p "$work/scripts" "$work/docs/stories"
cp "$REPO/scripts/verify-index-status.sh" "$work/scripts/verify-index-status.sh"
chmod +x "$work/scripts/verify-index-status.sh"
cat > "$work/docs/stories/INDEX.md" <<'EOF'
# Stories index
## Stories
| ID | Status | Slug | Title |
|----|--------|------|-------|
EOF
cat > "$work/docs/stories/KT-002-orphan.md" <<'EOF'
---
id: KT-002
status: shipped
---
EOF
out=$("$work/scripts/verify-index-status.sh" 2>&1) \
    && fail "verify-index-status unexpectedly exited 0 on missing INDEX row"
assert_contains "$out" "KT-002"  "verifier names the orphan story id"
assert_contains "$out" "missing" "verifier labels the row as missing"

# ── Scenario 8 — verify-index-status no-ops when INDEX.md absent ────────────
begin_test "verify-index-status no-ops when INDEX.md is absent"
tmpdir
work="$_LAST_TMPDIR"
mkdir -p "$work/scripts" "$work/docs/stories"
cp "$REPO/scripts/verify-index-status.sh" "$work/scripts/verify-index-status.sh"
chmod +x "$work/scripts/verify-index-status.sh"
# NB: do NOT create docs/stories/INDEX.md
out=$("$work/scripts/verify-index-status.sh" 2>&1) \
    || fail "verify-index-status should no-op (exit 0) when INDEX.md is absent"
assert_contains "$out" "nothing to check" "verifier emits no-op marker"

# ── Scenario 9 — _*.md templates are excluded from the story scan ───────────
begin_test "_story-template.md is excluded (template exclusion glob)"
tmpdir
work="$_LAST_TMPDIR"
mkdir -p "$work/scripts" "$work/docs/stories"
cp "$REPO/scripts/verify-index-status.sh" "$work/scripts/verify-index-status.sh"
chmod +x "$work/scripts/verify-index-status.sh"
cat > "$work/docs/stories/INDEX.md" <<'EOF'
# Stories index
## Stories
| ID | Status | Slug | Title |
|----|--------|------|-------|
EOF
# A template with status: draft and no INDEX row. If the exclusion works,
# the script passes; if it treats templates as stories, the script fails.
cat > "$work/docs/stories/_story-template.md" <<'EOF'
---
id: KT-NNN
status: draft
---
EOF
out=$("$work/scripts/verify-index-status.sh" 2>&1) \
    || fail "verify-index-status should exclude _*.md templates (output: $out)"
assert_contains "$out" "ok" "verifier reports ok with template present"

finish
