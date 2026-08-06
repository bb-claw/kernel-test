#!/bin/bash
# Tests for ns-variant config derivation and configs/namespaces.config.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── namespaces.config fragment ────────────────────────────────────────────────

begin_test "namespaces.config-exists"
assert_file_exists "$REPO/configs/namespaces.config" "namespaces.config present"

begin_test "namespaces.config-options"
ns_cfg=$(cat "$REPO/configs/namespaces.config")
assert_contains "$ns_cfg" "CONFIG_NAMESPACES=y"  "NAMESPACES=y"
assert_contains "$ns_cfg" "CONFIG_UTS_NS=y"      "UTS_NS=y"
assert_contains "$ns_cfg" "CONFIG_IPC_NS=y"      "IPC_NS=y"
assert_contains "$ns_cfg" "CONFIG_PID_NS=y"      "PID_NS=y"
assert_contains "$ns_cfg" "CONFIG_NET_NS=y"       "NET_NS=y"
assert_contains "$ns_cfg" "CONFIG_USER_NS=y"      "USER_NS=y"
assert_contains "$ns_cfg" "CONFIG_TIME_NS=y"      "TIME_NS=y"
assert_contains "$ns_cfg" "CONFIG_CGROUPS=y"      "CGROUPS=y"
assert_contains "$ns_cfg" "CONFIG_CGROUP_NS=y"    "CGROUP_NS=y"
assert_contains "$ns_cfg" "CONFIG_PROC_FS=y"      "PROC_FS=y"

# ── NS_BASE derivation: mirrors case statement in lib/build.sh ────────────────

derive_ns_base() {
    local config="$1"
    case "$config" in
        tinynsconfig)      echo tinyconfig ;;
        defnsconfig)       echo defconfig ;;
        kunitnsconfig)     echo kunitconfig ;;
        kunitrandnsconfig) echo kunitrandconfig ;;
        randnsconfig)      echo randconfig ;;
        rand500nsconfig)   echo rand500config ;;
        randdefnsconfig)   echo randdefconfig ;;
        *)                 echo "$config" ;;
    esac
}

begin_test "ns-base-derivation"
assert_eq "$(derive_ns_base tinynsconfig)"      "tinyconfig"      "tinynsconfig → tinyconfig"
assert_eq "$(derive_ns_base defnsconfig)"       "defconfig"       "defnsconfig → defconfig"
assert_eq "$(derive_ns_base kunitnsconfig)"     "kunitconfig"     "kunitnsconfig → kunitconfig"
assert_eq "$(derive_ns_base kunitrandnsconfig)" "kunitrandconfig" "kunitrandnsconfig → kunitrandconfig"
assert_eq "$(derive_ns_base randnsconfig)"      "randconfig"      "randnsconfig → randconfig"
assert_eq "$(derive_ns_base rand500nsconfig)"   "rand500config"   "rand500nsconfig → rand500config"
assert_eq "$(derive_ns_base randdefnsconfig)"   "randdefconfig"   "randdefnsconfig → randdefconfig"
# Non-ns configs are unchanged
assert_eq "$(derive_ns_base tinyconfig)"        "tinyconfig"      "tinyconfig unchanged"
assert_eq "$(derive_ns_base defconfig)"         "defconfig"       "defconfig unchanged"

# ── Makefile: randnsconfig in BUILD_ONLY_CONFIGS ─────────────────────────────

begin_test "makefile-build-only-configs"
mk=$(cat "$REPO/Makefile")
assert_contains "$mk" "randnsconfig" "randnsconfig in Makefile"
# Verify it appears in the BUILD_ONLY_CONFIGS line specifically
build_only_line=$(grep "^BUILD_ONLY_CONFIGS" "$REPO/Makefile")
assert_contains "$build_only_line" "randnsconfig" "randnsconfig in BUILD_ONLY_CONFIGS line"

# ── Makefile: ns-smoke target ─────────────────────────────────────────────────

begin_test "makefile-ns-smoke"
assert_contains "$mk" "ns-smoke"     "ns-smoke target defined"
assert_contains "$mk" "ns-full"      "ns-full target defined"
assert_contains "$mk" "kunitnsconfig" "kunitnsconfig in ns targets"
assert_contains "$mk" "tinynsconfig"  "tinynsconfig in ns targets"

finish
