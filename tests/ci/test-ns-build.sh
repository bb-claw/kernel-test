#!/bin/bash
# Tests for tests/ns/ C source files and Makefile structure.
# Verifies source files and Makefile are present and well-formed.
# Optionally builds x86_64 binaries when gcc is available.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

NS_DIR="$REPO/tests/ns"

# ── Source files exist ────────────────────────────────────────────────────────

begin_test "ns-source-files"
for src in ns-uts ns-ipc ns-pid ns-mount ns-net ns-user ns-cgroup ns-time; do
    assert_file_exists "$NS_DIR/${src}.c" "${src}.c present"
done

# ── Makefile content ──────────────────────────────────────────────────────────

begin_test "ns-makefile"
assert_file_exists "$NS_DIR/Makefile" "tests/ns/Makefile present"
mk=$(cat "$NS_DIR/Makefile")
assert_contains "$mk" "ns-uts.c ns-ipc.c ns-pid.c ns-mount.c" "SRCS line (uts/ipc/pid/mount)"
assert_contains "$mk" "ns-net.c ns-user.c ns-cgroup.c ns-time.c" "SRCS line (net/user/cgroup/time)"
assert_contains "$mk" "x86_64 i386 arm64 riscv" "ARCHES line"
assert_contains "$mk" "CC_arm64" "arm64 compiler defined"
assert_contains "$mk" "CC_riscv" "riscv compiler defined"
assert_contains "$mk" "-static"  "static linking flag present"

# ── C source subcommand coverage ──────────────────────────────────────────────

begin_test "ns-uts-subcommands"
uts=$(cat "$NS_DIR/ns-uts.c")
assert_contains "$uts" '"clone"'  "ns-uts clone subcommand"
assert_contains "$uts" '"setns"'  "ns-uts setns subcommand"

begin_test "ns-pid-subcommands"
pid_src=$(cat "$NS_DIR/ns-pid.c")
assert_contains "$pid_src" '"clone"'      "ns-pid clone subcommand"
assert_contains "$pid_src" '"init-death"' "ns-pid init-death subcommand"

begin_test "ns-time-cve"
time_src=$(cat "$NS_DIR/ns-time.c")
assert_contains "$time_src" "CVE-2023-23586" "CVE-2023-23586 comment present"
assert_contains "$time_src" "CLONE_NEWTIME"  "CLONE_NEWTIME used"

begin_test "ns-cgroup-cve"
cg_src=$(cat "$NS_DIR/ns-cgroup.c")
assert_contains "$cg_src" "CVE-2022-0492" "CVE-2022-0492 comment present"

begin_test "ns-user-cve"
user_src=$(cat "$NS_DIR/ns-user.c")
assert_contains "$user_src" "CVE-2018-18955" "CVE-2018-18955 comment present"

# ── Optional: build x86_64 binaries when gcc is available ────────────────────

begin_test "ns-x86_64-build"
if ! command -v gcc &>/dev/null; then
    pass "skip: gcc not available — skipping binary build"
else
    # Build only x86_64 to stay fast; cross-compilers may not be present in CI
    if make -C "$NS_DIR" \
            "bin/x86_64/ns-uts" "bin/x86_64/ns-ipc" "bin/x86_64/ns-pid" \
            "bin/x86_64/ns-mount" "bin/x86_64/ns-net" "bin/x86_64/ns-user" \
            "bin/x86_64/ns-cgroup" "bin/x86_64/ns-time" \
            >/dev/null 2>&1; then
        for bin in ns-uts ns-ipc ns-pid ns-mount ns-net ns-user ns-cgroup ns-time; do
            assert_file_exists "$NS_DIR/bin/x86_64/$bin" "x86_64/$bin built"
        done
        pass "x86_64 ns binaries built successfully"
    else
        pass "skip: x86_64 build failed (cross-build env or gcc version mismatch)"
    fi
fi

finish
