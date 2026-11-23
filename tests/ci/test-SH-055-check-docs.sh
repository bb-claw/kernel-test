#!/bin/bash
# SH-055 — fleet-wide check-docs wrapper (kernel-test adoption).
#
# CAPs: dev-cycle.tier.check-docs, dev-cycle.tier.hook-push (extended)
#
# The target name is fleet-uniform; the body is repo-native (verify-plan-docs).
# verify-plan-docs mirrors .githooks/pre-push section 4: every feat/SH-NNN-*
# or fix/SH-NNN-* branch must have docs/plans/SH-NNN-*-plan.md.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Scenario 1 — targets declared .PHONY ────────────────────────────────────
begin_test "check-docs and verify-plan-docs are .PHONY"
phony=$(awk '/^\.PHONY:/{flag=1} flag{printf "%s ", $0; if ($0 !~ /\\$/) {print ""; flag=0}}' "$REPO/Makefile")
assert_contains "$phony" "check-docs"       ".PHONY includes check-docs"
assert_contains "$phony" "verify-plan-docs" ".PHONY includes verify-plan-docs"

# ── Scenario 2 — dry-run resolves without executing recipes ─────────────────
begin_test "make -n check-docs resolves cleanly"
assert_exit0 "make -n check-docs succeeds" make -C "$REPO" -n check-docs

# ── Scenario 3 — check-docs expands to verify-plan-docs ─────────────────────
begin_test "check-docs body is verify-plan-docs"
out=$(make -C "$REPO" -n check-docs 2>&1)
assert_contains "$out" "verify-plan-docs.sh" "check-docs dry-run invokes verify-plan-docs.sh"

# ── Scenario 4 — PUSH_STEPS and ci-branch include check-docs ────────────────
begin_test "hook-push and ci-branch dry-runs invoke check-docs"
out=$(make -C "$REPO" -n hook-push 2>&1)
assert_contains "$out" "verify-plan-docs.sh" "hook-push expands PUSH_STEPS to include check-docs → verify-plan-docs"
out=$(make -C "$REPO" -n ci-branch 2>&1)
assert_contains "$out" "verify-plan-docs.sh" "ci-branch prereqs include check-docs → verify-plan-docs"

# ── Scenario 5 — verify-plan-docs green on matching feat/ branch ────────────
# Build a minimal throwaway repo on a feat/SH-NNN-* branch WITH the matching
# plan doc; the verifier should exit 0.
begin_test "verify-plan-docs passes when plan doc exists for feat/ branch"
tmpdir
work="$_LAST_TMPDIR"
cp "$REPO/scripts/verify-plan-docs.sh" "$work/verify-plan-docs.sh"
chmod +x "$work/verify-plan-docs.sh"
git init -q --initial-branch=main "$work"
git -C "$work" config user.email "test@example.com"
git -C "$work" config user.name  "CI Test"
git -C "$work" commit -q --allow-empty -m "initial"
git -C "$work" checkout -q -b feat/SH-999-fake-slug
mkdir -p "$work/docs/plans"
touch "$work/docs/plans/SH-999-fake-slug-plan.md"
out=$(cd "$work" && bash ./verify-plan-docs.sh 2>&1) \
    || fail "verify-plan-docs exited non-zero on matching feat/ branch"
assert_contains "$out" "ok: docs/plans/SH-999-fake-slug-plan.md" "verifier reports ok with plan path"

# ── Scenario 6 — verify-plan-docs FAILS on feat/ branch missing plan doc ────
begin_test "verify-plan-docs fails when plan doc missing for feat/ branch"
tmpdir
work="$_LAST_TMPDIR"
cp "$REPO/scripts/verify-plan-docs.sh" "$work/verify-plan-docs.sh"
chmod +x "$work/verify-plan-docs.sh"
git init -q --initial-branch=main "$work"
git -C "$work" config user.email "test@example.com"
git -C "$work" config user.name  "CI Test"
git -C "$work" commit -q --allow-empty -m "initial"
git -C "$work" checkout -q -b feat/SH-888-no-plan
# NB: do NOT create docs/plans/SH-888-no-plan-plan.md
out=$(cd "$work" && bash ./verify-plan-docs.sh 2>&1) \
    && fail "verify-plan-docs unexpectedly exited 0 on missing plan doc"
assert_contains "$out" "SH-888-no-plan-plan.md" "verifier names the expected plan path on failure"

# ── Scenario 7 — verify-plan-docs no-ops on non-feat/non-fix branch ─────────
begin_test "verify-plan-docs no-ops on docs/ or chore/ branches"
tmpdir
work="$_LAST_TMPDIR"
cp "$REPO/scripts/verify-plan-docs.sh" "$work/verify-plan-docs.sh"
chmod +x "$work/verify-plan-docs.sh"
git init -q --initial-branch=main "$work"
git -C "$work" config user.email "test@example.com"
git -C "$work" config user.name  "CI Test"
git -C "$work" commit -q --allow-empty -m "initial"
git -C "$work" checkout -q -b docs/some-slug
out=$(cd "$work" && bash ./verify-plan-docs.sh 2>&1) \
    || fail "verify-plan-docs should exit 0 on docs/ branch"
assert_contains "$out" "skip" "verifier emits skip marker on non-feat/fix branch"

finish
