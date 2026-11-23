#!/bin/bash
# SH-042 — fleet-wide hook-commit / hook-push tier wrappers.
#
# CAPs: dev-cycle.tier.hook-commit, dev-cycle.tier.hook-push
#
# The tier names are fleet-uniform; the step contents are repo-native and live
# in COMMIT_STEPS / PUSH_STEPS. For kernel-test:
#   COMMIT_STEPS = shellcheck-staged
#   PUSH_STEPS   = lint ci-test
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Scenario 1 — targets declared .PHONY ────────────────────────────────────
begin_test "hook-commit, hook-push, shellcheck-staged are .PHONY"
# Fold logical .PHONY: line (handles line-continuation) to one line then grep.
phony=$(awk '/^\.PHONY:/{flag=1} flag{printf "%s ", $0; if ($0 !~ /\\$/) {print ""; flag=0}}' "$REPO/Makefile")
assert_contains "$phony" "hook-commit"       ".PHONY includes hook-commit"
assert_contains "$phony" "hook-push"         ".PHONY includes hook-push"
assert_contains "$phony" "shellcheck-staged" ".PHONY includes shellcheck-staged"

# ── Scenario 2 — dry-run resolves without executing recipes ─────────────────
begin_test "make -n hook-commit / hook-push resolve cleanly"
assert_exit0 "make -n hook-commit succeeds" make -C "$REPO" -n hook-commit
assert_exit0 "make -n hook-push succeeds"   make -C "$REPO" -n hook-push

# ── Scenario 3 — hook-commit dry-run invokes shellcheck-staged ──────────────
begin_test "hook-commit expands to shellcheck-staged"
out=$(make -C "$REPO" -n hook-commit 2>&1)
assert_contains "$out" "shellcheck-staged" "hook-commit dry-run mentions shellcheck-staged marker"

# ── Scenario 4 — hook-push dry-run invokes lint and ci-test ─────────────────
begin_test "hook-push expands to lint + ci-test"
out=$(make -C "$REPO" -n hook-push 2>&1)
assert_contains "$out" "ci-lint.sh"     "hook-push dry-run invokes ci-lint.sh (lint)"
assert_contains "$out" "ci-run-tests.sh" "hook-push dry-run invokes ci-run-tests.sh (ci-test)"

# ── Scenario 5 — shellcheck-staged is a no-op with nothing staged ───────────
# When no *.sh files are staged, the target must exit 0 and print the skip
# marker so hook-commit stays within the ~15 s budget on empty commits.
begin_test "shellcheck-staged no-ops when no shell files are staged"
tmpdir
work="$_LAST_TMPDIR"
cp "$REPO/Makefile" "$work/Makefile"
# Minimal git repo so `git diff --cached` works and returns no entries.
git init -q --initial-branch=main "$work"
git -C "$work" config user.email "test@example.com"
git -C "$work" config user.name  "CI Test"
# Empty initial commit so `git diff --cached` is defined.
git -C "$work" commit -q --allow-empty -m "initial"
out=$(cd "$work" && make -f Makefile shellcheck-staged 2>&1) || fail "shellcheck-staged exited non-zero with no staged files"
assert_contains "$out" "no staged" "shellcheck-staged prints skip marker when nothing is staged"

finish
