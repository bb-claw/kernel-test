#!/bin/bash
# Tests for scripts/lint-context.sh — CLAUDE.md ≤ 150 lines, memory/*.md ≤ 150 lines.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

LINT_CTX="$REPO/scripts/lint-context.sh"

run_lint() { REPO_ROOT="$1" bash "$LINT_CTX" 2>&1; }

make_lines() { seq 1 "$1" | sed 's/.*//' > "$2"; }  # create file with exactly N lines

# ── CLAUDE.md checks ──────────────────────────────────────────────────────────

begin_test "lint-context: CLAUDE.md within 150 lines passes"
tmpdir
mkdir -p "$_LAST_TMPDIR/memory"
make_lines 150 "$_LAST_TMPDIR/CLAUDE.md"
if run_lint "$_LAST_TMPDIR" > /dev/null 2>&1; then pass; else fail "expected exit 0 for 150-line CLAUDE.md"; fi

begin_test "lint-context: CLAUDE.md over 150 lines fails"
tmpdir
mkdir -p "$_LAST_TMPDIR/memory"
make_lines 151 "$_LAST_TMPDIR/CLAUDE.md"
if run_lint "$_LAST_TMPDIR" > /dev/null 2>&1; then fail "expected exit 1 for 151-line CLAUDE.md"; else pass; fi

begin_test "lint-context: CLAUDE.md failure message mentions line count"
tmpdir
mkdir -p "$_LAST_TMPDIR/memory"
make_lines 151 "$_LAST_TMPDIR/CLAUDE.md"
out=$(run_lint "$_LAST_TMPDIR" 2>&1 || true)
assert_contains "$out" "151" "failure output contains line count"
pass

# ── memory/*.md checks ────────────────────────────────────────────────────────

begin_test "lint-context: memory file within 150 lines passes"
tmpdir
mkdir -p "$_LAST_TMPDIR/memory"
make_lines 150 "$_LAST_TMPDIR/CLAUDE.md"
make_lines 150 "$_LAST_TMPDIR/memory/code-quality.md"
if run_lint "$_LAST_TMPDIR" > /dev/null 2>&1; then pass; else fail "expected exit 0 for 150-line memory file"; fi

begin_test "lint-context: memory file over 150 lines fails"
tmpdir
mkdir -p "$_LAST_TMPDIR/memory"
make_lines 150 "$_LAST_TMPDIR/CLAUDE.md"
make_lines 151 "$_LAST_TMPDIR/memory/code-quality.md"
if run_lint "$_LAST_TMPDIR" > /dev/null 2>&1; then fail "expected exit 1 for 151-line memory file"; else pass; fi

begin_test "lint-context: MEMORY.md is exempt from the 150-line limit"
tmpdir
mkdir -p "$_LAST_TMPDIR/memory"
make_lines 150 "$_LAST_TMPDIR/CLAUDE.md"
make_lines 150 "$_LAST_TMPDIR/memory/MEMORY.md"
if run_lint "$_LAST_TMPDIR" > /dev/null 2>&1; then pass; else fail "MEMORY.md should be exempt from size limit"; fi

finish
