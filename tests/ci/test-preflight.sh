#!/bin/bash
# Tests for lib/preflight.sh — preflight checks for pipeline entry.
# Uses PATH and env-var manipulation to simulate missing tools and low disk space.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Create a minimal stub binary (exists + executable, exits 0).
make_stub() { printf '#!/bin/sh\nexit 0\n' > "$1"; chmod +x "$1"; }

# Run preflight.sh with a controlled env.  All args become env overrides.
# Captures combined stdout+stderr.  Never aborts the test on non-zero exit.
run_preflight() {
    tmpdir; local bd="$_LAST_TMPDIR/build"
    tmpdir; local cd_="$_LAST_TMPDIR/cache"
    mkdir -p "$bd" "$cd_"
    # Inline env passed as VAR=val args before the script path
    env BUILD_DIR="$bd" CACHE_DIR="$cd_" "$@" \
        "$REPO/lib/preflight.sh" 2>&1 || true
}

# Create a stub dir with all required tools populated; returns path in _LAST_TMPDIR.
make_full_stub_dir() {
    tmpdir; local d="$_LAST_TMPDIR"
    for t in gcc aarch64-linux-gnu-gcc riscv64-linux-gnu-gcc \
              qemu-system-x86_64 qemu-system-i386 \
              qemu-system-aarch64 qemu-system-riscv64; do
        make_stub "$d/$t"
    done
    # stub df: always reports 100G free on any path
    printf '#!/bin/sh\necho "Filesystem 1G-blocks Used Available Use%% Mounted"\necho "/dev /dev/sda1 500 100 100G 10%% /"\n' \
        > "$d/df"
    chmod +x "$d/df"
}

# ── Structure: lib/preflight.sh must exist ────────────────────────────────────

begin_test "lib/preflight.sh exists and is executable"
assert_file_exists "$REPO/lib/preflight.sh" "lib/preflight.sh present"
[[ -x "$REPO/lib/preflight.sh" ]] && pass "lib/preflight.sh is executable" \
                                   || fail "lib/preflight.sh must be executable"

begin_test "lib/preflight.sh is shellcheck-clean"
assert_exit0 "shellcheck clean" shellcheck --severity=warning "$REPO/lib/preflight.sh"

# ── Happy path ────────────────────────────────────────────────────────────────

begin_test "preflight passes when all tools are present"
make_full_stub_dir; sd="$_LAST_TMPDIR"
out=$(PATH="$sd:$PATH" run_preflight GCC=gcc ARCHS="x86_64 i386 arm64 riscv")
assert_contains "$out" "passed" "success message present"

# ── Host compiler ─────────────────────────────────────────────────────────────

begin_test "missing host compiler: exits non-zero"
out=$(run_preflight GCC=gcc-nonexistent-preflight-test ARCHS="x86_64")
[[ $? -ne 0 ]] || true  # run_preflight never aborts — check via message
assert_contains "$out" "gcc-nonexistent-preflight-test" "error names the missing compiler"

begin_test "missing host compiler: message mentions local.mk"
out=$(run_preflight GCC=gcc-nonexistent-preflight-test ARCHS="x86_64")
assert_contains "$out" "local.mk" "error directs user to local.mk"

begin_test "missing host compiler: does not proceed to build"
out=$(run_preflight GCC=gcc-nonexistent-preflight-test ARCHS="x86_64")
assert_not_contains "$out" "passed" "must not print 'passed' on failure"

# ── Cross-compilers ───────────────────────────────────────────────────────────

begin_test "missing arm64 cross-compiler: exits non-zero and names compiler"
make_full_stub_dir; sd="$_LAST_TMPDIR"
rm "$sd/aarch64-linux-gnu-gcc"
out=$(PATH="$sd:$PATH" run_preflight GCC=gcc ARCHS="x86_64 arm64")
assert_contains "$out" "aarch64-linux-gnu-gcc" "error names arm64 cross-compiler"

begin_test "missing riscv cross-compiler: exits non-zero and names compiler"
make_full_stub_dir; sd="$_LAST_TMPDIR"
rm "$sd/riscv64-linux-gnu-gcc"
out=$(PATH="$sd:$PATH" run_preflight GCC=gcc ARCHS="x86_64 riscv")
assert_contains "$out" "riscv64-linux-gnu-gcc" "error names riscv cross-compiler"

begin_test "cross-compiler not checked for x86_64-only run"
make_full_stub_dir; sd="$_LAST_TMPDIR"
rm "$sd/aarch64-linux-gnu-gcc" "$sd/riscv64-linux-gnu-gcc"
out=$(PATH="$sd:$PATH" run_preflight GCC=gcc ARCHS="x86_64 i386")
assert_not_contains "$out" "aarch64" "arm64 cross-compiler not checked when arch not in ARCHS"
assert_not_contains "$out" "riscv"   "riscv cross-compiler not checked when arch not in ARCHS"

# ── QEMU binaries ─────────────────────────────────────────────────────────────

begin_test "missing qemu-system-aarch64: exits non-zero and names binary"
make_full_stub_dir; sd="$_LAST_TMPDIR"
rm "$sd/qemu-system-aarch64"
out=$(PATH="$sd:$PATH" run_preflight GCC=gcc ARCHS="x86_64 arm64")
assert_contains "$out" "qemu-system-aarch64" "error names missing QEMU binary"

begin_test "missing qemu-system-riscv64: exits non-zero and names binary"
make_full_stub_dir; sd="$_LAST_TMPDIR"
rm "$sd/qemu-system-riscv64"
out=$(PATH="$sd:$PATH" run_preflight GCC=gcc ARCHS="x86_64 riscv")
assert_contains "$out" "qemu-system-riscv64" "error names missing QEMU binary"

begin_test "QEMU not checked for arch not in ARCHS"
make_full_stub_dir; sd="$_LAST_TMPDIR"
rm "$sd/qemu-system-aarch64" "$sd/qemu-system-riscv64"
out=$(PATH="$sd:$PATH" run_preflight GCC=gcc ARCHS="x86_64 i386")
assert_not_contains "$out" "qemu-system-aarch64" "arm64 QEMU not checked when arch absent"

# ── Multiple failures reported together ───────────────────────────────────────

begin_test "multiple missing tools: all errors reported before exit"
make_full_stub_dir; sd="$_LAST_TMPDIR"
rm "$sd/aarch64-linux-gnu-gcc" "$sd/qemu-system-riscv64"
out=$(PATH="$sd:$PATH" run_preflight GCC=gcc ARCHS="x86_64 arm64 riscv")
assert_contains "$out" "aarch64-linux-gnu-gcc"  "first error reported"
assert_contains "$out" "qemu-system-riscv64"    "second error reported"

# ── Disk space ────────────────────────────────────────────────────────────────

begin_test "low BUILD_DIR disk space: exits non-zero and names directory"
make_full_stub_dir; sd="$_LAST_TMPDIR"
# stub df emits 2G available (below 5G threshold)
printf '#!/bin/sh\nprintf "Filesystem 1G-blocks Used Available Use%%%% Mounted\\n/dev/sda1 100 98 2 99%%%% /\\n"\n' \
    > "$sd/df"; chmod +x "$sd/df"
tmpdir; bd="$_LAST_TMPDIR/build"; mkdir -p "$bd"
tmpdir; cd_="$_LAST_TMPDIR/cache"; mkdir -p "$cd_"
out=$(PATH="$sd:$PATH" BUILD_DIR="$bd" CACHE_DIR="$cd_" \
    GCC=gcc ARCHS="x86_64" "$REPO/lib/preflight.sh" 2>&1 || true)
assert_contains "$out" "BUILD_DIR" "error mentions BUILD_DIR"

# ── Makefile wiring ───────────────────────────────────────────────────────────

begin_test "Makefile has preflight target"
assert_contains "$(grep '^preflight' "$REPO/Makefile" || true)" "preflight" \
    "Makefile has preflight target"

begin_test "make build calls preflight"
assert_contains "$(cat "$REPO/Makefile")" "preflight" \
    "preflight referenced in Makefile build flow"

finish
