#!/bin/bash
# Tests for the 8 namespace VM test scripts (tests/custom/290_ns-*.sh – 360_ns-*.sh).
# Verifies structure, guards, and shellcheck compliance.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

NS_SCRIPTS=(
    290_ns-uts-ipc.sh
    300_ns-pid.sh
    310_ns-mount.sh
    320_ns-net.sh
    330_ns-user.sh
    340_ns-cgroup.sh
    350_ns-time.sh
    360_ns-setns.sh
)

# ── All scripts present and executable ───────────────────────────────────────

begin_test "ns-scripts-exist"
for s in "${NS_SCRIPTS[@]}"; do
    path="$REPO/tests/custom/$s"
    assert_file_exists "$path" "$s exists"
    if [[ -x "$path" ]]; then pass "$s is executable"
    else fail "$s is not executable"; fi
done

# ── POSIX sh shebang ─────────────────────────────────────────────────────────

begin_test "ns-scripts-shebang"
for s in "${NS_SCRIPTS[@]}"; do
    first=$(head -1 "$REPO/tests/custom/$s")
    assert_eq "$first" "#!/bin/sh" "$s has #!/bin/sh"
done

# ── Required boilerplate: fails counter + helper functions ───────────────────

begin_test "ns-scripts-boilerplate"
for s in "${NS_SCRIPTS[@]}"; do
    content=$(cat "$REPO/tests/custom/$s")
    assert_contains "$content" "fails=0"    "$s has fails=0"
    assert_contains "$content" 'ok()'       "$s has ok() function"
    assert_contains "$content" 'fail()'     "$s has fail() function"
    assert_contains "$content" 'skip()'     "$s has skip() function"
    assert_contains "$content" 'fails=$((fails + 1))' "$s increments fails counter"
done

# ── Namespace availability guard at top ───────────────────────────────────────

begin_test "ns-scripts-guard"
for s in "${NS_SCRIPTS[@]}"; do
    content=$(cat "$REPO/tests/custom/$s")
    assert_contains "$content" "/proc/self/ns/" "$s has /proc/self/ns/ guard"
done

# ── Exit pattern: [ $fails -eq 0 ] || exit 1 ─────────────────────────────────

begin_test "ns-scripts-exit"
for s in "${NS_SCRIPTS[@]}"; do
    content=$(cat "$REPO/tests/custom/$s")
    assert_contains "$content" "fails -eq 0" "$s has fails exit check"
done

# ── No awk (banned in VM test scripts) ───────────────────────────────────────

begin_test "ns-scripts-no-awk"
for s in "${NS_SCRIPTS[@]}"; do
    content=$(cat "$REPO/tests/custom/$s")
    assert_not_contains "$content" " awk " "$s has no awk"
done

# ── Shellcheck POSIX sh compliance ───────────────────────────────────────────

begin_test "ns-scripts-shellcheck"
if ! command -v shellcheck &>/dev/null; then
    pass "skip: shellcheck not available"
else
    for s in "${NS_SCRIPTS[@]}"; do
        path="$REPO/tests/custom/$s"
        if shellcheck --shell=sh "$path" >/dev/null 2>&1; then
            pass "$s shellcheck ok"
        else
            fail "$s shellcheck failed"
        fi
    done
fi

finish
