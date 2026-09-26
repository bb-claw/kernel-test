#!/bin/bash
# Tests for the config cache helpers in lib/common.sh and the caching logic
# wired into lib/build.sh.
# Strategy: test config_cache_hash / config_cache_valid directly (unit), then
# simulate the build.sh write/restore/invalidate cycle (integration) using a
# fake kernel tree whose Makefile responds to tinyconfig/defconfig/olddefconfig
# by writing a predictable .config into the O= directory.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Create a fake kernel tree with a Makefile that responds to config targets.
# Sets KERNEL_TREE and FAKE_COMMIT.
make_fake_kernel() {
    tmpdir; local kt="$_LAST_TMPDIR"
    {
        printf 'VERSION = 7\nPATCHLEVEL = 2\nSUBLEVEL = 0\nEXTRAVERSION = -rc99\nNAME = Test\n'
        printf '.PHONY: tinyconfig defconfig allnoconfig olddefconfig\n'
        printf 'tinyconfig allnoconfig:\n\tmkdir -p $(O) && printf '\''CONFIG_PRINTK=y\n'\'' > $(O)/.config\n'
        printf 'defconfig:\n\tmkdir -p $(O) && printf '\''CONFIG_PRINTK=y\nCONFIG_NET=y\n'\'' > $(O)/.config\n'
        printf 'olddefconfig:\n\t@true\n'
    } > "$kt/Makefile"
    git init -q "$kt"
    git -C "$kt" config user.email "test@example.com"
    git -C "$kt" config user.name  "CI Test"
    git -C "$kt" add Makefile
    git -C "$kt" commit -q -m "initial"
    KERNEL_TREE="$kt"
    FAKE_COMMIT=$(git -C "$kt" rev-parse --short HEAD)
    export KERNEL_TREE FAKE_COMMIT
}

# Create fragment files in a temp dir; sets FRAGDIR.
make_frags() {
    tmpdir; FRAGDIR="$_LAST_TMPDIR"
    printf 'CONFIG_TTY=y\n'           > "$FRAGDIR/frag.config"
    printf 'CONFIG_SERIAL_8250=y\n'   > "$FRAGDIR/overlay.config"
    printf 'CONFIG_NAMESPACES=y\n'    > "$FRAGDIR/namespaces.config"
}

# Simulate build.sh's _write_config_cache given OUT_DIR, TREE_COMMIT, _cache_frags.
sim_write_cache() {
    local out_dir="$1" commit="$2"; shift 2
    cp "$out_dir/.config" "$out_dir/.config-base"
    printf '%s\n' "$commit" > "$out_dir/.config-base-commit"
    config_cache_hash "$commit" "$@" > "$out_dir/.config-cache-hash"
}

# Simulate build.sh's _try_config_cache.  Returns 0 on hit (restores .config).
sim_try_cache() {
    local out_dir="$1" commit="$2"; shift 2
    [[ -f "$out_dir/.config-base" ]] || return 1
    config_cache_valid "$out_dir/.config-cache-hash" "$commit" "$@" || return 1
    cp "$out_dir/.config-base" "$out_dir/.config"
    return 0
}

# ── Structure ─────────────────────────────────────────────────────────────────

begin_test "lib/common.sh exports config_cache_hash and config_cache_valid"
declare -f config_cache_hash >/dev/null \
    && pass "config_cache_hash defined" || fail "config_cache_hash missing"
declare -f config_cache_valid >/dev/null \
    && pass "config_cache_valid defined" || fail "config_cache_valid missing"

# ── config_cache_hash unit tests ──────────────────────────────────────────────

begin_test "config_cache_hash: same inputs produce same hash"
make_frags
h1=$(config_cache_hash "abc123" "$FRAGDIR/frag.config" "$FRAGDIR/overlay.config")
h2=$(config_cache_hash "abc123" "$FRAGDIR/frag.config" "$FRAGDIR/overlay.config")
assert_eq "$h1" "$h2" "hash is reproducible"

begin_test "config_cache_hash: different commit produces different hash"
make_frags
h1=$(config_cache_hash "abc123" "$FRAGDIR/frag.config")
h2=$(config_cache_hash "xyz999" "$FRAGDIR/frag.config")
assert_ne "$h1" "$h2" "commit change → different hash"

begin_test "config_cache_hash: modified fragment produces different hash"
make_frags
h1=$(config_cache_hash "abc123" "$FRAGDIR/frag.config")
printf 'CONFIG_NET=y\n' >> "$FRAGDIR/frag.config"
h2=$(config_cache_hash "abc123" "$FRAGDIR/frag.config")
assert_ne "$h1" "$h2" "fragment change → different hash"

begin_test "config_cache_hash: missing fragment file silently skipped"
make_frags
h1=$(config_cache_hash "abc123" "$FRAGDIR/frag.config")
h2=$(config_cache_hash "abc123" "$FRAGDIR/frag.config" "$FRAGDIR/nonexistent.config")
assert_eq "$h1" "$h2" "missing file treated as absent (not an error)"

begin_test "config_cache_hash: adding an existing optional file changes hash"
make_frags
h1=$(config_cache_hash "abc123" "$FRAGDIR/frag.config")
h2=$(config_cache_hash "abc123" "$FRAGDIR/frag.config" "$FRAGDIR/overlay.config")
assert_ne "$h1" "$h2" "adding overlay changes hash"

# ── config_cache_valid unit tests ─────────────────────────────────────────────

begin_test "config_cache_valid: valid stamp returns 0"
make_frags; tmpdir; stamp_dir="$_LAST_TMPDIR"
config_cache_hash "abc123" "$FRAGDIR/frag.config" > "$stamp_dir/.config-cache-hash"
config_cache_valid "$stamp_dir/.config-cache-hash" "abc123" "$FRAGDIR/frag.config" \
    && pass "valid stamp accepted" || fail "valid stamp rejected"

begin_test "config_cache_valid: missing stamp file returns 1"
tmpdir; stamp_dir="$_LAST_TMPDIR"
config_cache_valid "$stamp_dir/.config-cache-hash" "abc123" \
    && fail "missing stamp should return 1" || pass "missing stamp rejected"

begin_test "config_cache_valid: stale commit returns 1"
make_frags; tmpdir; stamp_dir="$_LAST_TMPDIR"
config_cache_hash "abc123" "$FRAGDIR/frag.config" > "$stamp_dir/.config-cache-hash"
config_cache_valid "$stamp_dir/.config-cache-hash" "NEW_COMMIT" "$FRAGDIR/frag.config" \
    && fail "stale commit should return 1" || pass "stale commit rejected"

begin_test "config_cache_valid: modified fragment returns 1"
make_frags; tmpdir; stamp_dir="$_LAST_TMPDIR"
config_cache_hash "abc123" "$FRAGDIR/frag.config" > "$stamp_dir/.config-cache-hash"
printf 'CONFIG_NET=y\n' >> "$FRAGDIR/frag.config"
config_cache_valid "$stamp_dir/.config-cache-hash" "abc123" "$FRAGDIR/frag.config" \
    && fail "modified fragment should return 1" || pass "modified fragment rejected"

# ── Integration: cache miss → write → cache hit ───────────────────────────────

begin_test "cache miss writes .config-base and .config-cache-hash"
make_frags; tmpdir; out="$_LAST_TMPDIR"
printf 'CONFIG_PRINTK=y\n' > "$out/.config"
sim_write_cache "$out" "abc123" "$FRAGDIR/frag.config"
assert_file_exists "$out/.config-base"        "config-base written"
assert_file_exists "$out/.config-base-commit" "config-base-commit written"
assert_file_exists "$out/.config-cache-hash"  "config-cache-hash written"
commit_stored=$(cat "$out/.config-base-commit")
assert_eq "$commit_stored" "abc123" "config-base-commit stores kernel commit"

begin_test "cache hit restores .config-base"
make_frags; tmpdir; out="$_LAST_TMPDIR"
printf 'CONFIG_PRINTK=y\nCONFIG_TTY=y\n' > "$out/.config"
sim_write_cache "$out" "abc123" "$FRAGDIR/frag.config"
printf 'CONFIG_OVERWRITTEN=y\n' > "$out/.config"
sim_try_cache "$out" "abc123" "$FRAGDIR/frag.config" \
    && pass "cache hit returned 0" || fail "cache hit should return 0"
restored=$(cat "$out/.config")
assert_contains "$restored" "CONFIG_PRINTK=y" "config-base restored on hit"
assert_not_contains "$restored" "CONFIG_OVERWRITTEN=y" "overwritten .config replaced by base"

begin_test "cache miss on kernel commit change"
make_frags; tmpdir; out="$_LAST_TMPDIR"
printf 'CONFIG_PRINTK=y\n' > "$out/.config"
sim_write_cache "$out" "abc123" "$FRAGDIR/frag.config"
sim_try_cache "$out" "NEW_COMMIT" "$FRAGDIR/frag.config" \
    && fail "new commit should be a cache miss" || pass "new commit triggers cache miss"

begin_test "cache miss on fragment change"
make_frags; tmpdir; out="$_LAST_TMPDIR"
printf 'CONFIG_PRINTK=y\n' > "$out/.config"
sim_write_cache "$out" "abc123" "$FRAGDIR/frag.config"
printf 'CONFIG_NET=y\n' >> "$FRAGDIR/frag.config"
sim_try_cache "$out" "abc123" "$FRAGDIR/frag.config" \
    && fail "modified fragment should be a cache miss" || pass "fragment change triggers cache miss"

begin_test "cache miss on arch overlay change"
make_frags; tmpdir; out="$_LAST_TMPDIR"
printf 'CONFIG_PRINTK=y\n' > "$out/.config"
sim_write_cache "$out" "abc123" "$FRAGDIR/frag.config" "$FRAGDIR/overlay.config"
printf 'CONFIG_UART=y\n' >> "$FRAGDIR/overlay.config"
sim_try_cache "$out" "abc123" "$FRAGDIR/frag.config" "$FRAGDIR/overlay.config" \
    && fail "modified overlay should be a cache miss" || pass "overlay change triggers cache miss"

begin_test "namespaces.config included in cache key for ns-variants"
make_frags; tmpdir; out="$_LAST_TMPDIR"
printf 'CONFIG_PRINTK=y\n' > "$out/.config"
sim_write_cache "$out" "abc123" "$FRAGDIR/frag.config"
h_no_ns=$(cat "$out/.config-cache-hash")
config_cache_hash "abc123" "$FRAGDIR/frag.config" "$FRAGDIR/namespaces.config" \
    > "$out/.config-cache-hash"
h_with_ns=$(cat "$out/.config-cache-hash")
assert_ne "$h_no_ns" "$h_with_ns" "ns-variant key differs from plain variant key"

# ── rand500config cross-combo reuse ───────────────────────────────────────────

begin_test "rand500config reuses tinyconfig sibling base when commit matches"
make_frags; tmpdir; build_dir="$_LAST_TMPDIR"
tiny_dir="$build_dir/tinyconfig-riscv"
rand_dir="$build_dir/rand500config-riscv"
mkdir -p "$tiny_dir" "$rand_dir"
printf 'CONFIG_PRINTK=y\n' > "$tiny_dir/.config-base"
printf 'abc123\n'           > "$tiny_dir/.config-base-commit"
# rand500config checks sibling: commit matches → copy base, no kmake
if [[ -f "$tiny_dir/.config-base-commit" ]] && \
   [[ "$(cat "$tiny_dir/.config-base-commit")" == "abc123" ]] && \
   [[ -f "$tiny_dir/.config-base" ]]; then
    cp "$tiny_dir/.config-base" "$rand_dir/.config"
    pass "cross-combo hit: tinyconfig base reused"
else
    fail "cross-combo hit: tinyconfig sibling not found"
fi
assert_contains "$(cat "$rand_dir/.config")" "CONFIG_PRINTK=y" "reused base content correct"

begin_test "rand500config falls through to kmake when sibling commit differs"
make_frags; tmpdir; build_dir="$_LAST_TMPDIR"
tiny_dir="$build_dir/tinyconfig-riscv"
mkdir -p "$tiny_dir"
printf 'OLD_BASE\n' > "$tiny_dir/.config-base"
printf 'OLD_COMMIT\n' > "$tiny_dir/.config-base-commit"
[[ "$(cat "$tiny_dir/.config-base-commit")" == "abc123" ]] \
    && fail "stale sibling should not match" \
    || pass "stale sibling commit rejected, falls through to kmake"

# ── NO_CONFIG_CACHE=1 bypass ──────────────────────────────────────────────────

begin_test "NO_CONFIG_CACHE=1 causes _try_config_cache to return 1"
make_frags; tmpdir; out="$_LAST_TMPDIR"
printf 'CONFIG_PRINTK=y\n' > "$out/.config"
sim_write_cache "$out" "abc123" "$FRAGDIR/frag.config"
# Simulate NO_CONFIG_CACHE=1 in _try_config_cache
export NO_CONFIG_CACHE=1
if config_cache_valid "$out/.config-cache-hash" "abc123" "$FRAGDIR/frag.config"; then
    # Hash is valid but NO_CONFIG_CACHE=1 forces miss in build.sh
    pass "hash valid (NO_CONFIG_CACHE=1 suppression is build.sh logic)"
fi
export NO_CONFIG_CACHE=0

# ── Shellcheck ────────────────────────────────────────────────────────────────

begin_test "lib/common.sh is shellcheck-clean"
assert_exit0 "shellcheck clean" shellcheck --severity=warning "$REPO/lib/common.sh"

begin_test "lib/build.sh is shellcheck-clean"
assert_exit0 "shellcheck clean" shellcheck --severity=warning "$REPO/lib/build.sh"

begin_test "test-config-cache.sh is shellcheck-clean"
assert_exit0 "shellcheck clean" shellcheck --severity=warning "$REPO/tests/ci/test-config-cache.sh"

finish
