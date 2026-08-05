#!/bin/bash
# Tests for scripts/config-bisect.sh — filename parsing and candidate extraction.
# Only the pure-logic parts are tested; the kernel-build path is not exercised.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Filename parsing — extracted logic ────────────────────────────────────────
# Duplicates parse_archive_filename from config-bisect.sh so we can unit-test
# without executing the whole script (which requires CONFIG_FILE and KERNEL_TREE).

ARCHS_ALL="x86_64 i386 arm64 riscv"

parse_filename() {
    local path="$1"
    local stem
    stem="$(basename "$path" .config)"
    local sha
    sha=$(grep -oE '[0-9a-f]{64}' <<< "$stem" | head -1) || { echo "no-sha"; return 1; }
    local before
    before="${stem%%"$sha"*}"
    before="${before#kconfig-}"
    before="${before%-}"
    local arch=""
    for a in $ARCHS_ALL; do
        if [[ "$before" == *"-$a-"* || "$before" == *"-$a" ]]; then
            arch="$a"; break
        fi
    done
    local config="${before%%-"$arch"*}"
    local after="${stem##*"$sha"}"
    local failure="${after#-}"
    printf 'config=%s arch=%s sha=%s failure=%s\n' "$config" "$arch" "${sha:0:8}" "$failure"
}

begin_test "parse_filename: tinyconfig x86_64 passed"
sha="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
out=$(parse_filename "kconfig-tinyconfig-x86_64-v7.2-rc1-${sha}.config")
assert_contains "$out" "config=tinyconfig" "config extracted"
assert_contains "$out" "arch=x86_64"       "arch extracted"
assert_contains "$out" "failure="          "no failure suffix"

begin_test "parse_filename: rand500config i386 BOOT_FAIL"
sha="bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"
out=$(parse_filename "kconfig-rand500config-i386-v7.2-rc4-${sha}-BOOT_FAIL-timeout.config")
assert_contains "$out" "config=rand500config" "config extracted"
assert_contains "$out" "arch=i386"            "arch extracted"
assert_contains "$out" "failure=BOOT_FAIL-timeout" "failure type extracted"

begin_test "parse_filename: allmodconfig arm64 BUILD_TIMEOUT"
sha="cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
out=$(parse_filename "kconfig-allmodconfig-arm64-v7.1.5-${sha}-BUILD_TIMEOUT.config")
assert_contains "$out" "config=allmodconfig" "config extracted"
assert_contains "$out" "arch=arm64"          "arch extracted"
assert_contains "$out" "failure=BUILD_TIMEOUT" "failure type extracted"

# ── Candidate extraction — comm-based subtraction ─────────────────────────────

begin_test "extract_candidates removes baseline options"
tmpdir; workdir="$_LAST_TMPDIR"

# Simulate archived config (more options than baseline)
printf 'CONFIG_PRINTK=y\nCONFIG_TTY=y\nCONFIG_SERIAL_8250=y\nCONFIG_DEBUG_KERNEL=y\nCONFIG_KASAN=y\n' \
    | sort > "$workdir/archived.opts"

# Simulate baseline (tinyconfig + bootability)
printf 'CONFIG_PRINTK=y\nCONFIG_TTY=y\nCONFIG_SERIAL_8250=y\n' \
    | sort > "$workdir/baseline.opts"

# Candidates = archived - baseline
comm -23 "$workdir/archived.opts" "$workdir/baseline.opts" > "$workdir/candidates.txt"

out=$(cat "$workdir/candidates.txt")
assert_contains "$out" "CONFIG_DEBUG_KERNEL=y" "debug option is candidate"
assert_contains "$out" "CONFIG_KASAN=y"        "kasan option is candidate"
assert_not_contains "$out" "CONFIG_PRINTK=y"   "baseline option not a candidate"
assert_not_contains "$out" "CONFIG_TTY=y"      "baseline option not a candidate"

finish
