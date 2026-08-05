#!/bin/bash
# Tests for lib/fetch.sh — local-tag fallback and version recording.
# Does not require network access; uses local git tags in the test kernel tree.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
setup_git_stub

run_fetch() {
    local kt="$1" bdir="$2"
    KERNEL_TREE="$kt" \
    BUILD_DIR="$bdir" \
    "$REPO/lib/fetch.sh" 2>&1 || true
}

# ── local tag fallback ─────────────────────────────────────────────────────────
# ls-remote fails because the test kernel tree has no origin remote;
# fetch.sh must fall back to the local tag and still write .kernel-version.

begin_test "falls back to local tag when ls-remote fails"
setup_kernel_tree 7.2 -rc99
git -C "$KERNEL_TREE" tag v7.2-rc99
tmpdir; bdir="$_LAST_TMPDIR"
out=$(run_fetch "$KERNEL_TREE" "$bdir")
assert_contains "$out" "local" "fallback message emitted"
assert_file_exists "$bdir/.kernel-version" ".kernel-version written"
ver=$(cat "$bdir/.kernel-version")
assert_eq "$ver" "v7.2-rc99" "version matches local tag"

# ── tag already local skips fetch ─────────────────────────────────────────────

begin_test "skips fetch when tag already in local history"
setup_kernel_tree 7.2 -rc99
git -C "$KERNEL_TREE" tag v7.2-rc99
tmpdir; bdir="$_LAST_TMPDIR"
out=$(run_fetch "$KERNEL_TREE" "$bdir")
assert_contains "$out" "already in local history" "skip-fetch message present"
assert_file_exists "$bdir/.kernel-version" ".kernel-version still written"

# ── latest tag selected from multiple local tags ───────────────────────────────

begin_test "picks the latest rc tag from multiple local tags"
setup_kernel_tree 7.2 -rc5
git -C "$KERNEL_TREE" tag v7.2-rc3
git -C "$KERNEL_TREE" tag v7.2-rc5
tmpdir; bdir="$_LAST_TMPDIR"
run_fetch "$KERNEL_TREE" "$bdir" > /dev/null 2>&1 || true
ver=$(cat "$bdir/.kernel-version" 2>/dev/null || echo '')
assert_eq "$ver" "v7.2-rc5" "latest rc tag selected"

finish
