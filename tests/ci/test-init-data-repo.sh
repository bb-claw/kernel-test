#!/bin/bash
# Tests for scripts/init-data-repo.sh — directory creation, initial commit,
# idempotency, and error on non-git existing path.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
setup_git_stub

# ── creates expected structure ─────────────────────────────────────────────────

begin_test "creates git repo with expected directories"
tmpdir; dr="$_LAST_TMPDIR/data-repo"
"$REPO/scripts/init-data-repo.sh" "$dr" > /dev/null 2>&1
assert_exit0 "git repo initialised"       test -d "$dr/.git"
assert_exit0 "reports dir created"        test -d "$dr/reports"
assert_exit0 "archive_passed created"     test -d "$dr/configs/archive_passed"
assert_exit0 "archive_failed created"     test -d "$dr/configs/archive_failed"
assert_exit0 "dmesg dir created"          test -d "$dr/dmesg"
assert_file_exists "$dr/.gitignore"       ".gitignore present"
gi=$(cat "$dr/.gitignore")
assert_contains "$gi" "consolidation/" ".gitignore contains consolidation/"

# ── initial commit ────────────────────────────────────────────────────────────

begin_test "makes initial git commit"
tmpdir; dr="$_LAST_TMPDIR/data-repo"
"$REPO/scripts/init-data-repo.sh" "$dr" > /dev/null 2>&1
log=$(git -C "$dr" log --oneline)
assert_contains "$log" "initial" "initial commit present"

# ── idempotent ────────────────────────────────────────────────────────────────

begin_test "idempotent — second run exits 0 without adding a commit"
tmpdir; dr="$_LAST_TMPDIR/data-repo"
"$REPO/scripts/init-data-repo.sh" "$dr" > /dev/null 2>&1
"$REPO/scripts/init-data-repo.sh" "$dr" > /dev/null 2>&1
count=$(git -C "$dr" log --oneline | wc -l | tr -d ' ')
assert_eq "$count" "1" "exactly one commit after second run"

# ── error on existing non-git path ───────────────────────────────────────────

begin_test "exits 1 when path exists but is not a git repo"
tmpdir; dr="$_LAST_TMPDIR/not-a-repo"
mkdir -p "$dr"
assert_exit1 "exit 1 on non-git existing path" \
    "$REPO/scripts/init-data-repo.sh" "$dr"

finish
