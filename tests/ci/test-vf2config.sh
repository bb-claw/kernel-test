#!/bin/bash
# Tests for Phase 4 vf2config: config fragments exist, required options present,
# build.sh has the riscv-only arch guard.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

FRAG="$REPO/configs/vf2config.config"
OVERLAY="$REPO/configs/vf2config-riscv.config"
BUILD_SH="$REPO/lib/build.sh"

# ── Design doc: exists ───────────────────────────────────────────────────────

begin_test "vf2config-design-doc"
assert_file_exists "$REPO/docs/visionfive2-config-plan.md" "docs/visionfive2-config-plan.md present"
doc=$(cat "$REPO/docs/visionfive2-config-plan.md")
assert_contains "$doc" "vf2config"      "design doc mentions vf2config"
assert_contains "$doc" "JH7110"         "design doc mentions JH7110 SoC"
assert_contains "$doc" "DWMAC_STARFIVE" "design doc mentions Ethernet driver"

# ── Config fragment: exists ───────────────────────────────────────────────────

begin_test "vf2config-fragment-exists"
assert_file_exists "$FRAG" "configs/vf2config.config present"
content=$(cat "$FRAG")
if [[ -n "$content" ]]; then pass "configs/vf2config.config is non-empty"
else fail "configs/vf2config.config is empty"; fi

# ── Config fragment: required options ─────────────────────────────────────────

begin_test "vf2config-localversion"
assert_contains "$(cat "$FRAG")" 'CONFIG_LOCALVERSION="-vf2"' "LOCALVERSION=-vf2 pinned"

begin_test "vf2config-watchdog-sysfs"
assert_contains "$(cat "$FRAG")" "CONFIG_WATCHDOG_SYSFS=y" "WATCHDOG_SYSFS=y for 390_watchdog.sh"
assert_contains "$(cat "$FRAG")" "CONFIG_SOFT_WATCHDOG=y"  "SOFT_WATCHDOG=y for QEMU coverage"

begin_test "vf2config-jh7110-built-in"
frag=$(cat "$FRAG")
assert_contains "$frag" "CONFIG_STMMAC_ETH=y"             "STMMAC_ETH=y (dep of DWMAC)"
assert_contains "$frag" "CONFIG_STMMAC_PLATFORM=y"        "STMMAC_PLATFORM=y (dep of DWMAC)"
assert_contains "$frag" "CONFIG_DWMAC_STARFIVE=y"         "DWMAC_STARFIVE=y (Ethernet)"
assert_contains "$frag" "CONFIG_USB_CDNS3=y"              "USB_CDNS3=y (Cadence core, dep of _STARFIVE)"
assert_contains "$frag" "CONFIG_USB_CDNS3_STARFIVE=y"     "USB_CDNS3_STARFIVE=y"
assert_contains "$frag" "CONFIG_CLK_STARFIVE_JH7110_AON=y" "CLK AON=y"
assert_contains "$frag" "CONFIG_CLK_STARFIVE_JH7110_STG=y" "CLK STG=y"
assert_contains "$frag" "CONFIG_CLK_STARFIVE_JH7110_VOUT=y" "CLK VOUT=y (HDMI clock domain)"
assert_contains "$frag" "CONFIG_CLK_STARFIVE_JH7110_ISP=y"  "CLK ISP=y (camera clock domain)"
assert_contains "$frag" "CONFIG_PHY_STARFIVE_JH7110_USB=y"  "PHY USB=y"
assert_contains "$frag" "CONFIG_PCIE_STARFIVE_HOST=y"       "PCIE_STARFIVE_HOST=y (M.2 slot)"
assert_contains "$frag" "CONFIG_PHY_STARFIVE_JH7110_PCIE=y"  "PHY PCIE=y"
assert_contains "$frag" "CONFIG_HW_RANDOM_JH7110=y"          "HW_RANDOM_JH7110=y (hardware TRNG)"
assert_contains "$frag" "CONFIG_AMBA_PL08X=y"                "AMBA_PL08X=y (PL08x DMA, dep for crypto)"
assert_contains "$frag" "CONFIG_CRYPTO_DEV_JH7110=y"         "CRYPTO_DEV_JH7110=y (hardware AES/SHA)"
assert_contains "$frag" "CONFIG_STARFIVE_STARLINK_PMU=y"     "STARLINK_PMU=y (L3 cache PMU, perf relevance)"
assert_contains "$frag" "CONFIG_STARFIVE_STARLINK_CACHE=y"   "STARLINK_CACHE=y (cache controller, DMA coherency)"

begin_test "vf2config-heavy-subsystems-off"
frag=$(cat "$FRAG")
assert_contains "$frag" "CONFIG_DRM=n"           "DRM=n (build time)"
assert_contains "$frag" "CONFIG_SOUND=n"         "SOUND=n (build time)"
assert_contains "$frag" "CONFIG_MEDIA_SUPPORT=n" "MEDIA_SUPPORT=n (build time)"
assert_contains "$frag" "CONFIG_STAGING=n"       "STAGING=n (build time)"

begin_test "vf2config-modules-not-disabled"
frag=$(cat "$FRAG")
assert_not_contains "$frag" "CONFIG_MODULES=n" "MODULES=n not set (=m→=y strategy requires MODULES=y)"

# ── Arch overlay: exists ──────────────────────────────────────────────────────

begin_test "vf2config-overlay-exists"
assert_file_exists "$OVERLAY" "configs/vf2config-riscv.config present"

# ── build.sh: vf2config dispatch case ────────────────────────────────────────

begin_test "vf2config-build-dispatch"
bs=$(cat "$BUILD_SH")
assert_contains "$bs" "vf2config" "build.sh has vf2config case"
assert_contains "$bs" "vf2config is riscv-only" "build.sh has riscv-only guard message"

begin_test "vf2config-build-uses-defconfig-base"
bs=$(cat "$BUILD_SH")
assert_contains "$bs" 'EFFECTIVE_CONFIG == vf2config' "vf2config dispatch condition present"

# ── Makefile: vf2 target and help entry ──────────────────────────────────────

begin_test "vf2config-makefile-target"
mk=$(cat "$REPO/Makefile")
assert_contains "$mk" "vf2config ARCHS=riscv" "Makefile vf2 target uses CONFIGS=vf2config ARCHS=riscv"
assert_contains "$mk" "vf2config" "Makefile help mentions vf2config"

# ── 400_perf-events.sh: StarLink PMU opportunistic check ─────────────────────

begin_test "vf2config-perf-starlink-pmu-check"
perf=$(cat "$REPO/tests/custom/400_perf-events.sh")
assert_contains "$perf" "starfive-starlink-pmu" "400_perf-events.sh has StarLink PMU sysfs check"

finish
