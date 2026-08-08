#!/bin/bash
# Tests for ns-related changes in lib/initramfs.sh and lib/bootstrap.sh.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── initramfs.sh: usr/bin in mkdir ────────────────────────────────────────────

begin_test "initramfs-usr-bin-mkdir"
initramfs_sh=$(cat "$REPO/lib/initramfs.sh")
assert_contains "$initramfs_sh" "usr/bin" "usr/bin in mkdir line"

# ── initramfs.sh: per-(config,arch) args ─────────────────────────────────────

begin_test "initramfs-config-arg"
assert_contains "$initramfs_sh" 'CONFIG=${1:?'  "CONFIG is first required arg"
assert_contains "$initramfs_sh" 'ARCH=${2:?'    "ARCH is second required arg"
assert_contains "$initramfs_sh" 'initramfs-$CONFIG-$ARCH'  "output filename includes config and arch"

# ── initramfs.sh: NS_BIN_DIR copy loop ───────────────────────────────────────

begin_test "initramfs-ns-bin-dir"
assert_contains "$initramfs_sh" "NS_BIN_DIR"          "NS_BIN_DIR variable defined"
assert_contains "$initramfs_sh" 'tests/ns/bin/$ARCH'  "arch-specific ns bin path"
assert_contains "$initramfs_sh" "usr/bin/"            "copy destination is usr/bin/"
assert_contains "$initramfs_sh" "make bootstrap"      "skip message mentions bootstrap"

# ── initramfs.sh: capability marker files ────────────────────────────────────

begin_test "initramfs-markers"
assert_contains "$initramfs_sh" "ns-enabled"       "ns-enabled marker present"
assert_contains "$initramfs_sh" "perf-enabled"     "perf-enabled marker present"
assert_contains "$initramfs_sh" "arena-enabled"    "arena-enabled marker present"
assert_contains "$initramfs_sh" "watchdog-enabled" "watchdog-enabled marker present"
assert_contains "$initramfs_sh" "CONFIG_WATCHDOG=y" "watchdog marker greps .config"

# ── build.sh: EFFECTIVE_CONFIG and NS_BASE ────────────────────────────────────

begin_test "build-sh-effective-config"
build_sh=$(cat "$REPO/lib/build.sh")
assert_contains "$build_sh" "NS_BASE"           "NS_BASE variable defined"
assert_contains "$build_sh" "EFFECTIVE_CONFIG"  "EFFECTIVE_CONFIG variable defined"
assert_contains "$build_sh" "tinynsconfig"      "tinynsconfig case in NS_BASE derivation"
assert_contains "$build_sh" "rand500nsconfig"   "rand500nsconfig case in NS_BASE derivation"

# ── build.sh: namespaces.config applied for ns variants ──────────────────────

begin_test "build-sh-ns-fragment"
assert_contains "$build_sh" "NS_FRAGMENT"        "NS_FRAGMENT variable defined"
assert_contains "$build_sh" "namespaces.config"  "namespaces.config referenced"
assert_contains "$build_sh" "namespace fragment" "namespace fragment info message"

# ── bootstrap.sh: ns binary build step ───────────────────────────────────────

begin_test "bootstrap-ns-build"
boot_sh=$(cat "$REPO/lib/bootstrap.sh")
assert_contains "$boot_sh" "tests/ns"        "bootstrap references tests/ns"
assert_contains "$boot_sh" "make -C"         "bootstrap builds ns binaries"
assert_contains "$boot_sh" "namespace test binaries" "bootstrap info message present"

finish
