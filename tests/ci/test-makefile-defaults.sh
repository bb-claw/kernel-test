#!/bin/bash
# Tests for Makefile variable defaults — catches accidental API changes.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# Use 'make -n' with a dummy target to evaluate variable defaults without running anything.
# We print variables via a phony info target rather than parsing raw Makefile text.

get_var() {
    local var="$1"
    # Minimal env: no preset, no local.mk, stub KERNEL_TREE and DATA_REPO to avoid path errors
    make -C "$REPO" -f Makefile --no-print-directory \
        KERNEL_TREE=/tmp/fake-linux DATA_REPO=/tmp/fake-data \
        print-var-"$var" 2>/dev/null || true
}

begin_test "ARCHS_ALL contains all four architectures"
# Read directly from Makefile — grep is simpler than make for a constant
archs=$(grep '^ARCHS_ALL' "$REPO/Makefile" | head -1 | cut -d= -f2-)
assert_contains "$archs" "x86_64" "x86_64 in ARCHS_ALL"
assert_contains "$archs" "i386"   "i386 in ARCHS_ALL"
assert_contains "$archs" "arm64"  "arm64 in ARCHS_ALL"
assert_contains "$archs" "riscv"  "riscv in ARCHS_ALL"

begin_test "CONFIGS default contains all nine profiles"
configs=$(grep '^CONFIGS' "$REPO/Makefile" | head -1 | cut -d'?' -f2- | cut -d= -f2-)
for cfg in tinyconfig allnoconfig defconfig kunitconfig kunitrandconfig \
           allmodconfig randconfig rand500config randdefconfig; do
    assert_contains "$configs" "$cfg" "CONFIGS default includes $cfg"
done

begin_test "DATA_REPO default is HOME/git/kernel-test-data"
line=$(grep '^DATA_REPO' "$REPO/Makefile" | head -1)
assert_contains "$line" "git/kernel-test-data" "DATA_REPO default path"
assert_contains "$line" "HOME" "DATA_REPO uses HOME"

begin_test "REPORT_DIR defaults to DATA_REPO/reports"
line=$(grep '^REPORT_DIR' "$REPO/Makefile" | head -1)
assert_contains "$line" "DATA_REPO" "REPORT_DIR references DATA_REPO"
assert_contains "$line" "reports"   "REPORT_DIR ends with /reports"

begin_test "TIMEOUT default is 360"
line=$(grep '^TIMEOUT' "$REPO/Makefile" | head -1)
assert_contains "$line" "360" "TIMEOUT default 360"

begin_test "BUILD_TIMEOUT default is 1800"
line=$(grep '^BUILD_TIMEOUT' "$REPO/Makefile" | head -1)
assert_contains "$line" "1800" "BUILD_TIMEOUT default 1800"

begin_test "BUILD_ONLY_CONFIGS contains allmodconfig and randconfig"
line=$(grep '^BUILD_ONLY_CONFIGS' "$REPO/Makefile" | head -1)
assert_contains "$line" "allmodconfig" "allmodconfig in BUILD_ONLY_CONFIGS"
assert_contains "$line" "randconfig"   "randconfig in BUILD_ONLY_CONFIGS"

finish
