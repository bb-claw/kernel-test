#!/bin/bash
# CI tests for shared ccache auto-detect and ccache-init.
# Covers coverage-map paths: K1 (shared dir present → shared path),
# K2 (shared dir absent → local fallback), K3 (ccache-init idempotent),
# K4 (ccache.conf after init has expected keys).
# Does not require a kernel build or ccache already configured.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── K1: shared dir present → CCACHE_DIR resolves to shared path ─────────────

begin_test "ccache-auto-detect-shared"
tmpdir
_shared="$_LAST_TMPDIR/kernel-test-ccache"
mkdir -p "$_shared"
_out=$(make -s -C "$REPO" ccache-status SHARED_CCACHE_DIR="$_shared" 2>/dev/null)
assert_contains "$_out" "CCACHE_DIR=$_shared" "K1: shared dir used when present"

# ── K2: shared dir absent → CCACHE_DIR falls back to local cache/ ───────────

begin_test "ccache-auto-detect-local"
tmpdir
_absent="$_LAST_TMPDIR/no-such-dir"
_out=$(make -s -C "$REPO" ccache-status SHARED_CCACHE_DIR="$_absent" 2>/dev/null)
assert_contains "$_out" "CCACHE_DIR=$REPO/cache" "K2: falls back to local cache/"

# ── K3: ccache-init is idempotent ────────────────────────────────────────────

begin_test "ccache-init-idempotent"
tmpdir
_shared="$_LAST_TMPDIR/shared-cache"
# First run
make -s -C "$REPO" ccache-init SHARED_CCACHE_DIR="$_shared" 2>/dev/null
_conf1=""
[[ -f "$_shared/ccache.conf" ]] && _conf1=$(cat "$_shared/ccache.conf")
# Second run
make -s -C "$REPO" ccache-init SHARED_CCACHE_DIR="$_shared" 2>/dev/null
_conf2=""
[[ -f "$_shared/ccache.conf" ]] && _conf2=$(cat "$_shared/ccache.conf")
assert_eq "$_conf1" "$_conf2" "K3: ccache.conf unchanged on second ccache-init"

# ── K4: ccache.conf after init contains expected keys ───────────────────────

begin_test "ccache-init-config-keys"
tmpdir
_shared="$_LAST_TMPDIR/shared-cache2"
make -s -C "$REPO" ccache-init SHARED_CCACHE_DIR="$_shared" 2>/dev/null
_conf=""
[[ -f "$_shared/ccache.conf" ]] && _conf=$(cat "$_shared/ccache.conf")
assert_contains "$_conf" "max_size = 75G"      "K4: max_size=75G in ccache.conf"
assert_contains "$_conf" "sloppiness = time_macros" "K4: sloppiness=time_macros in ccache.conf"

finish
