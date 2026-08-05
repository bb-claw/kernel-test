#!/bin/bash
# Tests for scripts/migrate-reports.sh — old→new report dir rename.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

make_old_report() {
    local dir="$1" name="$2"
    mkdir -p "$dir/$name"
    printf 'BOOT=PASS\n' > "$dir/$name/vmstatus-tinyconfig-x86_64.txt"
}

# ── dry-run shows renames without touching dirs ───────────────────────────────

begin_test "dry-run shows rename plan"
tmpdir; rd="$_LAST_TMPDIR"
make_old_report "$rd" "2026-01-01_10-00-00_v7.2-rc1"
out=$(REPORT_DIR="$rd" "$REPO/scripts/migrate-reports.sh" 2>&1)
assert_contains "$out" "mainline" "dry-run suggests mainline label"
[[ -d "$rd/2026-01-01_10-00-00_v7.2-rc1" ]]
pass "directory untouched in dry-run"

# ── --apply renames the directory ────────────────────────────────────────────

begin_test "--apply renames old-format dir"
tmpdir; rd="$_LAST_TMPDIR"
make_old_report "$rd" "2026-01-01_10-00-00_v7.2-rc1"
REPORT_DIR="$rd" "$REPO/scripts/migrate-reports.sh" --apply 2>&1
[[ ! -d "$rd/2026-01-01_10-00-00_v7.2-rc1" ]]
pass "old dir removed"
new=$(find "$rd" -maxdepth 1 -mindepth 1 -type d | head -1)
assert_contains "$new" "mainline" "new dir has label prefix"

# ── already-new-format dirs are skipped ──────────────────────────────────────

begin_test "new-format dirs skipped by migrate"
tmpdir; rd="$_LAST_TMPDIR"
mkdir -p "$rd/mainline-7.2-2026-01-01_10-00-00-v7.2-rc1"
out=$(REPORT_DIR="$rd" "$REPO/scripts/migrate-reports.sh" 2>&1)
assert_not_contains "$out" "mainline-7.2-2026-01-01" "new-format dir not listed as candidate"

# ── baseline symlink updated on --apply ───────────────────────────────────────

begin_test "baseline symlink updated after rename"
tmpdir; rd="$_LAST_TMPDIR"
make_old_report "$rd" "2026-01-01_10-00-00_v7.2-rc1"
ln -s "2026-01-01_10-00-00_v7.2-rc1" "$rd/baseline"
REPORT_DIR="$rd" "$REPO/scripts/migrate-reports.sh" --apply 2>&1
new_target=$(readlink "$rd/baseline")
assert_contains "$new_target" "mainline" "baseline symlink points to renamed dir"

finish
