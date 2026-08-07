#!/bin/bash
# Tests for the arch-specific VM test scripts (370_riscv-isa, 380_arm64-features,
# 400_perf-events): structure, skip guards, shellcheck compliance.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

ARCH_SCRIPTS=(
    370_riscv-isa.sh
    380_arm64-features.sh
    400_perf-events.sh
    410_arena-memory.sh
)

# ── Scripts present and executable ───────────────────────────────────────────

begin_test "arch-scripts-exist"
for s in "${ARCH_SCRIPTS[@]}"; do
    path="$REPO/tests/custom/$s"
    assert_file_exists "$path" "$s exists"
    if [[ -x "$path" ]]; then pass "$s is executable"
    else fail "$s is not executable"; fi
done

# ── POSIX sh shebang ─────────────────────────────────────────────────────────

begin_test "arch-scripts-shebang"
for s in "${ARCH_SCRIPTS[@]}"; do
    first=$(head -1 "$REPO/tests/custom/$s")
    assert_eq "$first" "#!/bin/sh" "$s has #!/bin/sh"
done

# ── Required boilerplate ─────────────────────────────────────────────────────

begin_test "arch-scripts-boilerplate"
for s in "${ARCH_SCRIPTS[@]}"; do
    content=$(cat "$REPO/tests/custom/$s")
    assert_contains "$content" "fails=0"              "$s has fails=0"
    assert_contains "$content" 'ok()'                 "$s has ok() function"
    assert_contains "$content" 'fail()'               "$s has fail() function"
    assert_contains "$content" 'skip()'               "$s has skip() function"
    assert_contains "$content" 'fails=$((fails + 1))' "$s increments fails"
done

# ── No awk ───────────────────────────────────────────────────────────────────

begin_test "arch-scripts-no-awk"
for s in "${ARCH_SCRIPTS[@]}"; do
    content=$(cat "$REPO/tests/custom/$s")
    assert_not_contains "$content" " awk " "$s has no awk"
done

# ── Inventory coverage ────────────────────────────────────────────────────────

begin_test "arch-scripts-inventory"
inv="$REPO/memory/test-inventory.md"
assert_file_exists "$inv" "test-inventory.md exists"
for slot in 370 380 400 410; do
    assert_contains "$(cat "$inv")" "${slot}_" "slot ${slot}_ in inventory"
done

# ── Skip guard: 370_riscv-isa.sh skips on non-riscv ─────────────────────────

begin_test "arch-script-370-skip-on-x86_64"
tmpdir
printf '#!/bin/sh\necho "x86_64"\n' > "$_LAST_TMPDIR/uname"
chmod +x "$_LAST_TMPDIR/uname"
out=$(PATH="$_LAST_TMPDIR:$PATH" bash "$REPO/tests/custom/370_riscv-isa.sh" 2>&1); rc=$?
assert_eq   "$rc" "0"    "exits 0 on x86_64"
assert_contains "$out" "skip" "prints skip on x86_64"

# ── Skip guard: 380_arm64-features.sh skips on non-arm64 ────────────────────

begin_test "arch-script-380-skip-on-x86_64"
tmpdir
printf '#!/bin/sh\necho "x86_64"\n' > "$_LAST_TMPDIR/uname"
chmod +x "$_LAST_TMPDIR/uname"
out=$(PATH="$_LAST_TMPDIR:$PATH" bash "$REPO/tests/custom/380_arm64-features.sh" 2>&1); rc=$?
assert_eq   "$rc" "0"    "exits 0 on x86_64"
assert_contains "$out" "skip" "prints skip on x86_64"

# ── Skip guard: 400_perf-events.sh skips when binary absent ─────────────────

begin_test "arch-script-400-skip-no-binary"
out=$(PERF_BIN=/nonexistent/perf-event bash "$REPO/tests/custom/400_perf-events.sh" 2>&1); rc=$?
assert_eq   "$rc" "0"    "exits 0 when binary absent"
assert_contains "$out" "skip" "prints skip when binary absent"

# ── Skip guard: 410_arena-memory.sh skips when binary absent ─────────────────
# /usr/bin/arena-test does not exist on the CI host (VM-only path) → must skip.

begin_test "arch-script-410-skip-no-binary"
out=$(bash "$REPO/tests/custom/410_arena-memory.sh" 2>&1); rc=$?
assert_eq   "$rc" "0"    "exits 0 when binary absent"
assert_contains "$out" "skip" "prints skip when binary absent"

# ── Shellcheck POSIX sh compliance ───────────────────────────────────────────

begin_test "arch-scripts-shellcheck"
if ! command -v shellcheck &>/dev/null; then
    pass "skip: shellcheck not available"
else
    for s in "${ARCH_SCRIPTS[@]}"; do
        path="$REPO/tests/custom/$s"
        if shellcheck --shell=sh --severity=warning "$path" >/dev/null 2>&1; then
            pass "$s shellcheck ok"
        else
            fail "$s shellcheck failed"
        fi
    done
fi

finish
