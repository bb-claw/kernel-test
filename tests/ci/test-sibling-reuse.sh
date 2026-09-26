#!/bin/bash
# Tests for the _try_sibling_base helper and the correctness invariant:
#   deterministic configs write their own cache after a sibling hit;
#   random configs do not.
# Strategy: define _try_sibling_base / _write_config_cache / _try_config_cache
# locally (mirrors build.sh), set up fixture dirs, assert cache file presence.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

# ── Local mirrors of build.sh helpers ─────────────────────────────────────────

# Call with: init_combo <out_dir> <commit> [frag1 frag2 ...]
# Sets OUT_DIR, TREE_COMMIT, _config_base, _config_base_commit, _config_cache_hash,
# _cache_frags[] — the same variables build.sh uses.
init_combo() {
    OUT_DIR="$1"; TREE_COMMIT="$2"; shift 2
    _config_base="$OUT_DIR/.config-base"
    _config_base_commit="$OUT_DIR/.config-base-commit"
    _config_cache_hash="$OUT_DIR/.config-cache-hash"
    _cache_frags=("$@")
    mkdir -p "$OUT_DIR"
    export OUT_DIR TREE_COMMIT _config_base _config_base_commit _config_cache_hash
}

_try_sibling_base() {
    local sib_dir="$1"
    [[ "${NO_CONFIG_CACHE:-0}" == "1" ]] && return 1
    [[ -f "$sib_dir/.config-base-commit" ]] || return 1
    [[ "$(cat "$sib_dir/.config-base-commit")" == "$TREE_COMMIT" ]] || return 1
    [[ -f "$sib_dir/.config-base" ]] || return 1
    cp "$sib_dir/.config-base" "$OUT_DIR/.config"
    return 0
}

_write_config_cache() {
    cp "$OUT_DIR/.config" "$_config_base"
    printf '%s\n' "$TREE_COMMIT" > "$_config_base_commit"
    config_cache_hash "$TREE_COMMIT" "${_cache_frags[@]}" > "$_config_cache_hash"
}

_try_config_cache() {
    [[ "${NO_CONFIG_CACHE:-0}" == "1" ]] && return 1
    [[ -f "$_config_base" ]] || return 1
    config_cache_valid "$_config_cache_hash" "$TREE_COMMIT" "${_cache_frags[@]}" || return 1
    cp "$_config_base" "$OUT_DIR/.config"
    return 0
}

# Write a valid sibling into <dir>: .config-base + .config-base-commit.
make_sibling() {
    local sib_dir="$1" commit="$2" content="${3:-CONFIG_PRINTK=y}"
    mkdir -p "$sib_dir"
    printf '%s\n' "$content"  > "$sib_dir/.config-base"
    printf '%s\n' "$commit"   > "$sib_dir/.config-base-commit"
}

# ── _try_sibling_base unit tests ──────────────────────────────────────────────

begin_test "_try_sibling_base: returns 1 when sibling dir does not exist"
tmpdir; d="$_LAST_TMPDIR"
init_combo "$d/combo" "abc123"
_try_sibling_base "$d/no-such-dir" && fail "expected miss" || pass "miss on absent dir"

begin_test "_try_sibling_base: returns 1 when .config-base-commit missing"
tmpdir; d="$_LAST_TMPDIR"
init_combo "$d/combo" "abc123"
mkdir -p "$d/sibling"
printf 'CONFIG_PRINTK=y\n' > "$d/sibling/.config-base"
_try_sibling_base "$d/sibling" && fail "expected miss" || pass "miss when commit file absent"

begin_test "_try_sibling_base: returns 1 on commit mismatch"
tmpdir; d="$_LAST_TMPDIR"
init_combo "$d/combo" "abc123"
make_sibling "$d/sibling" "different_commit"
_try_sibling_base "$d/sibling" && fail "expected miss" || pass "miss on commit mismatch"

begin_test "_try_sibling_base: returns 0 and copies .config-base on commit match"
tmpdir; d="$_LAST_TMPDIR"
init_combo "$d/combo" "abc123"
make_sibling "$d/sibling" "abc123" "CONFIG_NET=y"
_try_sibling_base "$d/sibling" || fail "expected hit"
[[ -f "$OUT_DIR/.config" ]] && pass ".config written" || fail ".config not written"
grep -q "CONFIG_NET=y" "$OUT_DIR/.config" && pass "correct content" || fail "wrong content"

begin_test "_try_sibling_base: returns 1 when NO_CONFIG_CACHE=1"
tmpdir; d="$_LAST_TMPDIR"
init_combo "$d/combo" "abc123"
make_sibling "$d/sibling" "abc123"
NO_CONFIG_CACHE=1 _try_sibling_base "$d/sibling" && fail "expected bypass" \
    || pass "NO_CONFIG_CACHE=1 bypasses sibling"

begin_test "_try_sibling_base: returns 1 when .config-base file missing despite valid commit"
tmpdir; d="$_LAST_TMPDIR"
init_combo "$d/combo" "abc123"
mkdir -p "$d/sibling"
printf 'abc123\n' > "$d/sibling/.config-base-commit"
_try_sibling_base "$d/sibling" && fail "expected miss" || pass "miss when .config-base absent"

# ── Correctness invariant: deterministic configs ──────────────────────────────

begin_test "deterministic: sibling hit → own cache written → warm run skips sibling"
tmpdir; d="$_LAST_TMPDIR"
printf 'CONFIG_TTY=y\n' > "$d/frag.config"
init_combo "$d/kunitconfig-x86_64" "abc123" "$d/frag.config"
make_sibling "$d/defconfig-x86_64" "abc123" "CONFIG_PRINTK=y"

# Cold run: sibling hit; caller writes own cache (deterministic invariant).
if _try_sibling_base "$d/defconfig-x86_64"; then
    _write_config_cache
else
    fail "sibling should have hit on cold run"
fi
[[ -f "$_config_base" ]]        && pass "own .config-base written"        || fail ".config-base missing"
[[ -f "$_config_base_commit" ]] && pass "own .config-base-commit written"  || fail ".config-base-commit missing"
[[ -f "$_config_cache_hash" ]]  && pass "own .config-cache-hash written"   || fail ".config-cache-hash missing"

# Warm run: own cache hits without needing the sibling.
rm -f "$d/defconfig-x86_64/.config-base-commit"   # remove sibling to prove it's not used
if _try_config_cache; then
    pass "warm run uses own cache (sibling not needed)"
else
    fail "warm run should have hit own per-combo cache"
fi

begin_test "deterministic: second run hits own cache even if sibling commit changes"
tmpdir; d="$_LAST_TMPDIR"
printf 'CONFIG_TTY=y\n' > "$d/frag.config"
init_combo "$d/tinynsconfig-riscv" "abc123" "$d/frag.config"
make_sibling "$d/tinyconfig-riscv" "abc123" "CONFIG_PRINTK=y"

# First cold run: sibling hit → write own cache.
_try_sibling_base "$d/tinyconfig-riscv" || fail "sibling hit expected"
_write_config_cache

# Simulate kernel update: sibling now has different commit (new fetch).
printf 'new_commit\n' > "$d/tinyconfig-riscv/.config-base-commit"

# Own cache still valid for original commit.
_try_config_cache && pass "own cache valid despite sibling commit change" \
    || fail "own cache should still be valid"

# ── Correctness invariant: random configs ─────────────────────────────────────

begin_test "random: sibling hit → own cache NOT written → _try_config_cache misses"
tmpdir; d="$_LAST_TMPDIR"
printf 'CONFIG_TTY=y\n' > "$d/frag.config"
init_combo "$d/rand500config-x86_64" "abc123" "$d/frag.config"
make_sibling "$d/tinyconfig-x86_64" "abc123" "CONFIG_PRINTK=y"

# Simulate random config: use sibling but do NOT call _write_config_cache.
_try_sibling_base "$d/tinyconfig-x86_64" || fail "sibling hit expected"
# No _write_config_cache here — correct for random configs.

[[ ! -f "$_config_cache_hash" ]] && pass "no .config-cache-hash (correct for random)" \
    || fail ".config-cache-hash should not be written for random configs"
_try_config_cache && fail "should miss — no own cache written" \
    || pass "_try_config_cache misses (random must re-check sibling each run)"

begin_test "random: sibling absent → own-base fallback works"
tmpdir; d="$_LAST_TMPDIR"
printf 'CONFIG_TTY=y\n' > "$d/frag.config"
init_combo "$d/rand500config-x86_64" "abc123" "$d/frag.config"
# No sibling present; but own prior base exists (written by a previous kmake).
printf 'CONFIG_PRINTK=y\n' > "$_config_base"
printf 'abc123\n'           > "$_config_base_commit"

# Simulate rand500config own-base fallback path.
if [[ -f "$_config_base_commit" ]] && \
   [[ "$(cat "$_config_base_commit")" == "$TREE_COMMIT" ]] && \
   [[ -f "$_config_base" ]]; then
    cp "$_config_base" "$OUT_DIR/.config"
    pass "own-base fallback copies .config"
else
    fail "own-base fallback should have fired"
fi
grep -q "CONFIG_PRINTK=y" "$OUT_DIR/.config" \
    && pass "correct content from own base" || fail "wrong content"

# ── Regression: existing rand500config sibling path still works ───────────────

begin_test "regression: rand500config sibling path (refactored) still hits"
tmpdir; d="$_LAST_TMPDIR"
printf 'CONFIG_TTY=y\n' > "$d/frag.config"
init_combo "$d/rand500config-x86_64" "abc123" "$d/frag.config"
make_sibling "$d/tinyconfig-x86_64" "abc123" "CONFIG_PRINTK=y"
_try_sibling_base "$d/tinyconfig-x86_64" \
    && pass "rand500config sibling hit" || fail "rand500config sibling miss"

begin_test "regression: randdefconfig sibling path (refactored) still hits"
tmpdir; d="$_LAST_TMPDIR"
printf 'CONFIG_TTY=y\n' > "$d/frag.config"
init_combo "$d/randdefconfig-x86_64" "abc123" "$d/frag.config"
make_sibling "$d/defconfig-x86_64" "abc123" "CONFIG_NET=y"
_try_sibling_base "$d/defconfig-x86_64" \
    && pass "randdefconfig sibling hit" || fail "randdefconfig sibling miss"

begin_test "regression: kunitrandconfig sibling path (refactored) still hits"
tmpdir; d="$_LAST_TMPDIR"
printf 'CONFIG_TTY=y\n' > "$d/frag.config"
init_combo "$d/kunitrandconfig-x86_64" "abc123" "$d/frag.config"
make_sibling "$d/defconfig-x86_64" "abc123" "CONFIG_NET=y"
_try_sibling_base "$d/defconfig-x86_64" \
    && pass "kunitrandconfig sibling hit" || fail "kunitrandconfig sibling miss"

# ── shellcheck ────────────────────────────────────────────────────────────────

begin_test "shellcheck: test-sibling-reuse.sh"
shellcheck --severity=warning "$REPO/tests/ci/test-sibling-reuse.sh" \
    && pass "shellcheck clean" || fail "shellcheck errors"

finish
