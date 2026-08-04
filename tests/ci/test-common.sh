#!/bin/bash
# Tests for lib/common.sh pure helper functions.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

# ── arch_cross_compile ────────────────────────────────────────────────────────

begin_test "arch_cross_compile"
assert_eq "$(arch_cross_compile arm64)"  "aarch64-linux-gnu-"  "arm64 prefix"
assert_eq "$(arch_cross_compile riscv)"  "riscv64-linux-gnu-"  "riscv prefix"
assert_eq "$(arch_cross_compile x86_64)" ""                    "x86_64 native"
assert_eq "$(arch_cross_compile i386)"   ""                    "i386 native"

# ── arch_kernel_image ─────────────────────────────────────────────────────────

begin_test "arch_kernel_image"
assert_eq "$(arch_kernel_image x86_64)" "bzImage" "x86_64 image"
assert_eq "$(arch_kernel_image i386)"   "bzImage" "i386 image"
assert_eq "$(arch_kernel_image arm64)"  "Image"   "arm64 image"
assert_eq "$(arch_kernel_image riscv)"  "Image"   "riscv image"

# ── arch_toybox_name ──────────────────────────────────────────────────────────

begin_test "arch_toybox_name"
assert_eq "$(arch_toybox_name x86_64)" "x86_64"  "x86_64 toybox"
assert_eq "$(arch_toybox_name i386)"   "i686"    "i386 toybox"
assert_eq "$(arch_toybox_name arm64)"  "aarch64" "arm64 toybox"
assert_eq "$(arch_toybox_name riscv)"  "riscv64" "riscv toybox"

# ── apply_arch_overlay ────────────────────────────────────────────────────────

begin_test "apply_arch_overlay"
tmpdir; cfgdir="$_LAST_TMPDIR"
dot_config="$cfgdir/.config"
printf 'CONFIG_BASE=y\n' > "$dot_config"
# overlay present — should be appended
printf 'CONFIG_OVERLAY=y\n' > "$cfgdir/tinyconfig-x86_64.config"
apply_arch_overlay "$dot_config" "$cfgdir" "tinyconfig" "x86_64"
assert_contains "$(cat "$dot_config")" "CONFIG_OVERLAY=y" "overlay appended"
# overlay absent — should be a no-op (no error)
assert_exit0 "no-overlay-no-error" apply_arch_overlay "$dot_config" "$cfgdir" "tinyconfig" "arm64"

# ── read_kernel_makefile_version ──────────────────────────────────────────────

begin_test "read_kernel_makefile_version"
setup_kernel_tree "7.2" "-rc5"
ver=$(KERNEL_TREE="$KERNEL_TREE" read_kernel_makefile_version)
assert_eq "$ver" "v7.2-rc5" "rc tag format"

setup_kernel_tree "7.1" ".3"
ver2=$(KERNEL_TREE="$KERNEL_TREE" read_kernel_makefile_version)
assert_eq "$ver2" "v7.1.3" "stable tag format"

finish
