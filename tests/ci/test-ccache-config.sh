#!/bin/bash
# Tests for ccache configuration in Makefile, build.sh, and install.sh.
# Verifies defaults, --set-config persistence, and conditional tuning behaviour.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Makefile: variable defaults ───────────────────────────────────────────────

begin_test "CCACHE_MAX_SIZE default is 25G"
line=$(grep '^CCACHE_MAX_SIZE' "$REPO/Makefile" | head -1)
assert_contains "$line" "25G" "CCACHE_MAX_SIZE ?= 25G"

begin_test "CCACHE_TUNE default is 1"
line=$(grep '^CCACHE_TUNE' "$REPO/Makefile" | head -1)
assert_contains "$line" "1" "CCACHE_TUNE ?= 1"

begin_test "CCACHE_MAX_SIZE and CCACHE_TUNE are exported"
export_line=$(grep '^export KERNEL_TREE' "$REPO/Makefile" | head -1)
assert_contains "$export_line" "CCACHE_MAX_SIZE" "CCACHE_MAX_SIZE in export line"
assert_contains "$export_line" "CCACHE_TUNE"     "CCACHE_TUNE in export line"

# ── build.sh: settings persisted via --set-config ────────────────────────────

begin_test "build.sh persists max_size via --set-config"
content=$(cat "$REPO/lib/build.sh")
assert_contains "$content" 'ccache --set-config' "build.sh calls ccache --set-config"
assert_contains "$content" 'max_size'             "build.sh sets max_size"
assert_contains "$content" 'CCACHE_MAX_SIZE'      "build.sh references CCACHE_MAX_SIZE"

begin_test "build.sh persists sloppiness=time_macros when CCACHE_TUNE=1"
assert_contains "$(cat "$REPO/lib/build.sh")" 'sloppiness=time_macros' \
    "build.sh sets sloppiness=time_macros"

begin_test "build.sh persists compression_level=1 when CCACHE_TUNE=1"
assert_contains "$(cat "$REPO/lib/build.sh")" 'compression_level=1' \
    "build.sh sets compression_level=1"

begin_test "build.sh persists base_dir when CCACHE_TUNE=1"
assert_contains "$(cat "$REPO/lib/build.sh")" 'base_dir=' \
    "build.sh sets base_dir"

begin_test "build.sh does not set hard_link (objtool modifies .o files in-place)"
assert_not_contains "$(cat "$REPO/lib/build.sh")" 'hard_link=true' \
    "build.sh must not set hard_link=true"

begin_test "build.sh resets tuning settings when CCACHE_TUNE=0"
content=$(cat "$REPO/lib/build.sh")
assert_contains "$content" 'compression_level=0'  "build.sh resets compression_level=0"

begin_test "build.sh tuning is conditional on CCACHE_TUNE"
assert_contains "$(cat "$REPO/lib/build.sh")" 'CCACHE_TUNE' \
    "build.sh checks CCACHE_TUNE"

# ── install.sh: settings persisted via --set-config ──────────────────────────

begin_test "install.sh persists max_size via --set-config"
content=$(cat "$REPO/lib/install.sh")
assert_contains "$content" 'ccache --set-config' "install.sh calls ccache --set-config"
assert_contains "$content" 'max_size'             "install.sh sets max_size"

begin_test "install.sh persists sloppiness=time_macros when CCACHE_TUNE=1"
assert_contains "$(cat "$REPO/lib/install.sh")" 'sloppiness=time_macros' \
    "install.sh sets sloppiness=time_macros"

begin_test "install.sh persists compression_level=1 when CCACHE_TUNE=1"
assert_contains "$(cat "$REPO/lib/install.sh")" 'compression_level=1' \
    "install.sh sets compression_level=1"

begin_test "install.sh does not set hard_link (objtool modifies .o files in-place)"
assert_not_contains "$(cat "$REPO/lib/install.sh")" 'hard_link=true' \
    "install.sh must not set hard_link=true"

begin_test "install.sh resets tuning settings when CCACHE_TUNE=0"
content=$(cat "$REPO/lib/install.sh")
assert_contains "$content" 'compression_level=0'  "install.sh resets compression_level=0"

begin_test "install.sh tuning is conditional on CCACHE_TUNE"
assert_contains "$(cat "$REPO/lib/install.sh")" 'CCACHE_TUNE' \
    "install.sh checks CCACHE_TUNE"

# ── Structural: tuning block is after CCACHE_DIR in both scripts ──────────────

begin_test "build.sh: --set-config appears after CCACHE_DIR"
content=$(cat "$REPO/lib/build.sh")
dir_pos=$(echo "$content" | grep -n 'CCACHE_DIR=' | head -1 | cut -d: -f1)
cfg_pos=$(echo "$content" | grep -n 'ccache --set-config' | head -1 | cut -d: -f1)
assert_ne "$dir_pos" "" "CCACHE_DIR found in build.sh"
assert_ne "$cfg_pos" "" "--set-config found in build.sh"
[[ "$cfg_pos" -gt "$dir_pos" ]] && pass "--set-config after CCACHE_DIR" \
                                 || fail "--set-config should appear after CCACHE_DIR"

begin_test "install.sh: --set-config appears after CCACHE_DIR"
content=$(cat "$REPO/lib/install.sh")
dir_pos=$(echo "$content" | grep -n 'CCACHE_DIR=' | head -1 | cut -d: -f1)
cfg_pos=$(echo "$content" | grep -n 'ccache --set-config' | head -1 | cut -d: -f1)
assert_ne "$dir_pos" "" "CCACHE_DIR found in install.sh"
assert_ne "$cfg_pos" "" "--set-config found in install.sh"
[[ "$cfg_pos" -gt "$dir_pos" ]] && pass "--set-config after CCACHE_DIR" \
                                 || fail "--set-config should appear after CCACHE_DIR"

finish
