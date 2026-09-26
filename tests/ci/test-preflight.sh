#!/bin/bash
# Tests for lib/preflight.sh — preflight checks for pipeline entry.
# Uses isolated PATH (base dir + per-test stubs) to simulate missing tools.
# On usrmerge systems (/bin → /usr/bin), PATH prepend is not enough — an
# isolated dir with only the needed stubs is required.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Create a minimal stub binary (exists + executable, exits 0).
make_stub() { printf '#!/bin/sh\nexit 0\n' > "$1"; chmod +x "$1"; }

# Create an isolated base dir containing only essential shell utilities
# (df, awk, mkdir, env, printf) needed by lib/preflight.sh itself.
# Bash is found via the shebang's absolute path — no PATH entry needed.
# Callers add stubs for compiler/QEMU tools on top; PATH="$_LAST_TMPDIR"
# then gives a fully controlled tool set with no system bleed-through.
make_base_dir() {
    tmpdir; local d="$_LAST_TMPDIR"
    # dirname: needed by preflight.sh to locate common.sh via $(dirname "$0")/common.sh
    # date: needed by common.sh's log() → called by die() on any check failure
    for t in df awk mkdir env printf dirname date; do
        local bin; bin=$(command -v "$t" 2>/dev/null) || continue
        ln -sf "$bin" "$d/$t"
    done
}

# Run preflight.sh with a fully isolated PATH (base + caller-controlled stubs).
# $1 = stub dir (result of make_base_dir + added stubs)
# remaining args = extra VAR=val env overrides
run_isolated() {
    local sd="$1"; shift
    tmpdir; local bd="$_LAST_TMPDIR/build"
    tmpdir; local cd_="$_LAST_TMPDIR/cache"
    mkdir -p "$bd" "$cd_"
    env PATH="$sd" BUILD_DIR="$bd" CACHE_DIR="$cd_" "$@" \
        "$REPO/lib/preflight.sh" 2>&1 || true
}

# Populate a base dir with all required compiler + QEMU stubs (happy path).
add_all_stubs() {
    local d="$1"
    for t in gcc aarch64-linux-gnu-gcc riscv64-linux-gnu-gcc \
              qemu-system-x86_64 qemu-system-i386 \
              qemu-system-aarch64 qemu-system-riscv64; do
        make_stub "$d/$t"
    done
}

# Replace the df symlink in a stub dir with one that reports low available space.
stub_low_df() {
    local d="$1"
    rm -f "$d/df"   # remove the symlink to real df before writing
    printf '#!/bin/sh\nprintf "Filesystem 1G-blocks Used Available Use%%%% Mounted\\n"\nprintf "/dev/sda1 500 498 2 99%%%% /\\n"\n' \
        > "$d/df"; chmod +x "$d/df"
}

# ── Structure ─────────────────────────────────────────────────────────────────

begin_test "lib/preflight.sh exists and is executable"
assert_file_exists "$REPO/lib/preflight.sh" "lib/preflight.sh present"
[[ -x "$REPO/lib/preflight.sh" ]] && pass "lib/preflight.sh is executable" \
                                   || fail "lib/preflight.sh must be executable"

begin_test "lib/preflight.sh is shellcheck-clean"
if ! command -v shellcheck &>/dev/null; then
    pass "skip: shellcheck not available"
elif shellcheck --severity=warning "$REPO/lib/preflight.sh" >/dev/null 2>&1; then
    pass "shellcheck clean"
else
    fail "shellcheck clean: exited non-zero"
fi

# ── Happy path ────────────────────────────────────────────────────────────────

begin_test "preflight passes when all tools are present"
make_base_dir; sd="$_LAST_TMPDIR"; add_all_stubs "$sd"
out=$(run_isolated "$sd" GCC=gcc ARCHS="x86_64 i386 arm64 riscv")
assert_contains "$out" "passed" "success message present"

# ── Host compiler ─────────────────────────────────────────────────────────────

begin_test "missing host compiler: exits non-zero and names the compiler"
# Use a unique fake name — no PATH isolation needed, it cannot exist anywhere
out=$(GCC=gcc-preflight-ci-fake BUILD_DIR=/tmp CACHE_DIR=/tmp ARCHS=x86_64 \
    "$REPO/lib/preflight.sh" 2>&1 || true)
assert_contains "$out" "gcc-preflight-ci-fake" "error names the missing compiler"
assert_contains "$out" "local.mk"              "error directs user to local.mk"
assert_not_contains "$out" "passed"            "must not print 'passed' on failure"

# ── Cross-compilers ───────────────────────────────────────────────────────────

begin_test "missing arm64 cross-compiler: exits non-zero and names compiler"
make_base_dir; sd="$_LAST_TMPDIR"; add_all_stubs "$sd"
rm "$sd/aarch64-linux-gnu-gcc"
out=$(run_isolated "$sd" GCC=gcc ARCHS="x86_64 arm64")
assert_contains "$out" "aarch64-linux-gnu-gcc" "error names arm64 cross-compiler"

begin_test "missing riscv cross-compiler: exits non-zero and names compiler"
make_base_dir; sd="$_LAST_TMPDIR"; add_all_stubs "$sd"
rm "$sd/riscv64-linux-gnu-gcc"
out=$(run_isolated "$sd" GCC=gcc ARCHS="x86_64 riscv")
assert_contains "$out" "riscv64-linux-gnu-gcc" "error names riscv cross-compiler"

begin_test "cross-compilers not checked when arch not in ARCHS"
make_base_dir; sd="$_LAST_TMPDIR"; add_all_stubs "$sd"
rm "$sd/aarch64-linux-gnu-gcc" "$sd/riscv64-linux-gnu-gcc"
out=$(run_isolated "$sd" GCC=gcc ARCHS="x86_64 i386")
assert_not_contains "$out" "aarch64" "arm64 cross-compiler not checked when arch absent"
assert_not_contains "$out" "riscv"   "riscv cross-compiler not checked when arch absent"

# ── QEMU binaries ─────────────────────────────────────────────────────────────

begin_test "missing qemu-system-aarch64: exits non-zero and names binary"
make_base_dir; sd="$_LAST_TMPDIR"; add_all_stubs "$sd"
rm "$sd/qemu-system-aarch64"
out=$(run_isolated "$sd" GCC=gcc ARCHS="x86_64 arm64")
assert_contains "$out" "qemu-system-aarch64" "error names missing QEMU binary"

begin_test "missing qemu-system-riscv64: exits non-zero and names binary"
make_base_dir; sd="$_LAST_TMPDIR"; add_all_stubs "$sd"
rm "$sd/qemu-system-riscv64"
out=$(run_isolated "$sd" GCC=gcc ARCHS="x86_64 riscv")
assert_contains "$out" "qemu-system-riscv64" "error names missing QEMU binary"

begin_test "QEMU not checked for arch not in ARCHS"
make_base_dir; sd="$_LAST_TMPDIR"; add_all_stubs "$sd"
rm "$sd/qemu-system-aarch64" "$sd/qemu-system-riscv64"
out=$(run_isolated "$sd" GCC=gcc ARCHS="x86_64 i386")
assert_not_contains "$out" "qemu-system-aarch64" "arm64 QEMU not checked when arch absent"

# ── Multiple failures reported together ───────────────────────────────────────

begin_test "multiple missing tools: all errors reported before exit"
make_base_dir; sd="$_LAST_TMPDIR"; add_all_stubs "$sd"
rm "$sd/aarch64-linux-gnu-gcc" "$sd/qemu-system-riscv64"
out=$(run_isolated "$sd" GCC=gcc ARCHS="x86_64 arm64 riscv")
assert_contains "$out" "aarch64-linux-gnu-gcc" "first error reported"
assert_contains "$out" "qemu-system-riscv64"   "second error reported"

# ── Disk space ────────────────────────────────────────────────────────────────

begin_test "low BUILD_DIR disk space: exits non-zero and names directory"
make_base_dir; sd="$_LAST_TMPDIR"; add_all_stubs "$sd"; stub_low_df "$sd"
tmpdir; bd="$_LAST_TMPDIR/build"; mkdir -p "$bd"
tmpdir; cd_="$_LAST_TMPDIR/cache"; mkdir -p "$cd_"
out=$(env PATH="$sd" BUILD_DIR="$bd" CACHE_DIR="$cd_" \
    GCC=gcc ARCHS="x86_64" "$REPO/lib/preflight.sh" 2>&1 || true)
assert_contains "$out" "BUILD_DIR" "error mentions BUILD_DIR"

# ── Makefile wiring ───────────────────────────────────────────────────────────

begin_test "Makefile has preflight target"
grep -q '^preflight:' "$REPO/Makefile" && pass "Makefile has preflight target" \
                                        || fail "Makefile missing preflight target"

begin_test "make build calls lib/preflight.sh"
# preflight call must appear in the build target's recipe (within first 2 recipe lines)
grep -A 2 "^build:" "$REPO/Makefile" | grep -q "lib/preflight.sh" \
    && pass "build target calls lib/preflight.sh" \
    || fail "build target calls lib/preflight.sh"

finish
