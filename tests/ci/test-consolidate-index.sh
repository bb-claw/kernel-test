#!/bin/bash
# Tests for scripts/consolidate-index.sh — cross-source merge logic.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="$REPO/tests/ci/fixtures"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── merge two sources ─────────────────────────────────────────────────────────

begin_test "consolidate-index merges two sources"
setup_data_repo
cp -r "$FIXTURES/consolidation/local-mainline"   "$DATA_REPO/consolidation/"
cp -r "$FIXTURES/consolidation/hetzner-mainline" "$DATA_REPO/consolidation/"

"$REPO/scripts/consolidate-index.sh" 2>&1

assert_file_exists "$DATA_REPO/consolidation/index.txt"  "index.txt written"
assert_file_exists "$DATA_REPO/consolidation/index.html" "index.html written"
out=$(cat "$DATA_REPO/consolidation/index.txt")
assert_contains "$out" "local-mainline"    "local-mainline source column"
assert_contains "$out" "hetzner-mainline"  "hetzner-mainline source column"
assert_contains "$out" "tinyconfig"        "tinyconfig entry"
assert_contains "$out" "allmodconfig"      "allmodconfig entry"

# ── dedup: same SHA from same source appears once; same SHA different source twice ──

begin_test "dedup: same SHA across two sources = two rows"
# aaaa1111… appears in both local-mainline and hetzner-mainline (cross-source = two rows)
count=$(grep -c "aaaa1111" "$DATA_REPO/consolidation/index.txt" || true)
assert_eq "$count" "2" "same SHA from two sources = two rows"

# ── zero sources — graceful exit ──────────────────────────────────────────────

begin_test "consolidate-index handles zero sources"
setup_data_repo
assert_exit0 "zero-sources-exit0" "$REPO/scripts/consolidate-index.sh"

# ── html contains SOURCE column header ───────────────────────────────────────

begin_test "html output has SOURCE column"
setup_data_repo
cp -r "$FIXTURES/consolidation/local-mainline" "$DATA_REPO/consolidation/"
"$REPO/scripts/consolidate-index.sh" 2>&1
html=$(cat "$DATA_REPO/consolidation/index.html")
assert_contains "$html" "Source" "Source column in html"

finish
