#!/bin/bash
# CI tests for lib/monitor.sh --once snapshot mode.
# Covers coverage-map paths: M1 (exits 0 with no active run), M2 (BUILDS/TESTS headers).
# Does not require a running kernel build, QEMU, or ccache.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── M1: --once exits 0 with no active run ────────────────────────────────────

begin_test "monitor-once-exits-0"
tmpdir
_bd="$_LAST_TMPDIR/build-absent"
_rd="$_LAST_TMPDIR/reports"
mkdir -p "$_rd"
assert_exit0 "M1: --once exits 0 with absent build dir" \
    env BUILD_DIR="$_bd" REPORT_DIR="$_rd" bash "$REPO/lib/monitor.sh" --once

# ── M2: output contains BUILDS and TESTS section headers ─────────────────────

begin_test "monitor-once-section-headers"
tmpdir
_bd="$_LAST_TMPDIR/build"
_rd="$_LAST_TMPDIR/reports"
mkdir -p "$_bd" "$_rd"
_mon_out=$(BUILD_DIR="$_bd" REPORT_DIR="$_rd" bash "$REPO/lib/monitor.sh" --once 2>&1) || true
assert_contains "$_mon_out" "BUILDS" "M2: BUILDS header present"
assert_contains "$_mon_out" "TESTS"  "M2: TESTS header present"

finish
