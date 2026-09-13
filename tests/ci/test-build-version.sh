#!/bin/bash
# Tests for kernel version identification in lib/build.sh.
#
# Regression: git describe --tags --abbrev=0 returned the wrong ancestor tag
# on stable-rc clones (e.g. v7.1-rc7 instead of v7.2.6-rc1) because the
# linux-stable-rc remote does not carry stable release tags at the branch tip.
# Fix: fall back to read_kernel_makefile_version (same as report.sh).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

# Create a kernel tree with explicit SUBLEVEL (stable point releases need it).
# Args: major minor sublevel extraversion
# Sets and exports KERNEL_TREE.
setup_stable_tree() {
    local major="$1" minor="$2" sublevel="$3" extraversion="$4"
    tmpdir
    local kt="$_LAST_TMPDIR"
    {
        printf 'VERSION = %s\n'      "$major"
        printf 'PATCHLEVEL = %s\n'   "$minor"
        printf 'SUBLEVEL = %s\n'     "$sublevel"
        printf 'EXTRAVERSION = %s\n' "$extraversion"
        printf 'NAME = Test\n'
    } > "$kt/Makefile"
    git init -q "$kt"
    git -C "$kt" config user.email "test@example.com"
    git -C "$kt" config user.name  "CI Test"
    git -C "$kt" add Makefile
    git -C "$kt" commit -q -m "initial"
    KERNEL_TREE="$kt"
    export KERNEL_TREE
}

# Add an extra commit to advance HEAD past the initial commit.
advance_head() {
    printf '# bump\n' >> "$KERNEL_TREE/Makefile"
    git -C "$KERNEL_TREE" add Makefile
    git -C "$KERNEL_TREE" commit -q -m "Linux 7.2.6-rc1"
}

# ── read_kernel_makefile_version: stable point release ────────────────────────

begin_test "read_kernel_makefile_version: stable point release (SUBLEVEL > 0)"
setup_stable_tree 7 2 6 -rc1
ver=$(read_kernel_makefile_version)
assert_eq "$ver" "v7.2.6-rc1" "correct stable-rc version from Makefile"

begin_test "read_kernel_makefile_version: mainline RC (SUBLEVEL = 0)"
setup_kernel_tree "7.2" "-rc5"
ver=$(read_kernel_makefile_version)
assert_eq "$ver" "v7.2-rc5" "correct mainline version from Makefile"

# ── stable-rc scenario: ancestor has old tag, HEAD is untagged ───────────────

begin_test "git describe --exact-match fails when HEAD is untagged (stable-rc branch tip)"
setup_stable_tree 7 2 6 -rc1
git -C "$KERNEL_TREE" tag v7.1-rc7      # old-series tag on initial commit
advance_head                             # HEAD is now one commit past the tag
exact=$(git -C "$KERNEL_TREE" describe --exact-match HEAD 2>/dev/null || echo "NOTAG")
assert_eq "$exact" "NOTAG" "exact-match fails on untagged HEAD"

begin_test "git describe --tags --abbrev=0 returns wrong ancestor tag (old behaviour)"
setup_stable_tree 7 2 6 -rc1
git -C "$KERNEL_TREE" tag v7.1-rc7
advance_head
wrong=$(git -C "$KERNEL_TREE" describe --tags --abbrev=0 HEAD 2>/dev/null || echo "FAIL")
assert_eq "$wrong" "v7.1-rc7" "abbrev=0 surfaces ancestor tag from different series"

begin_test "fixed expression returns Makefile version when no exact tag (stable-rc)"
setup_stable_tree 7 2 6 -rc1
git -C "$KERNEL_TREE" tag v7.1-rc7
advance_head
ver=$(git -C "$KERNEL_TREE" describe --exact-match HEAD 2>/dev/null \
      || read_kernel_makefile_version)
assert_eq "$ver" "v7.2.6-rc1" "fixed expression: Makefile version wins over ancestor tag"
assert_ne "$ver" "v7.1-rc7"   "fixed expression: old ancestor tag not returned"

# ── mainline scenario: exact tag at HEAD (no regression) ─────────────────────

begin_test "git describe --exact-match succeeds on mainline (tag present at HEAD)"
setup_kernel_tree "7.2" "-rc5"
git -C "$KERNEL_TREE" tag v7.2-rc5
ver=$(git -C "$KERNEL_TREE" describe --exact-match HEAD 2>/dev/null \
      || read_kernel_makefile_version)
assert_eq "$ver" "v7.2-rc5" "mainline: exact tag takes precedence over Makefile"

finish
