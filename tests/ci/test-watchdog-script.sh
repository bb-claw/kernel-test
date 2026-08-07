#!/bin/bash
# Tests for tests/custom/390_watchdog.sh: structure, skip guard, shellcheck.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

SCRIPT="$REPO/tests/custom/390_watchdog.sh"

# ── File-level checks ─────────────────────────────────────────────────────────

begin_test "watchdog-script-exists"
assert_file_exists "$SCRIPT" "390_watchdog.sh exists"
if [[ -x "$SCRIPT" ]]; then pass "390_watchdog.sh is executable"
else fail "390_watchdog.sh is not executable"; fi

begin_test "watchdog-script-shebang"
first=$(head -1 "$SCRIPT")
assert_eq "$first" "#!/bin/sh" "has #!/bin/sh shebang"

begin_test "watchdog-script-boilerplate"
content=$(cat "$SCRIPT")
assert_contains "$content" "fails=0"              "has fails=0"
assert_contains "$content" 'ok()'                 "has ok() function"
assert_contains "$content" 'fail()'               "has fail() function"
assert_contains "$content" 'skip()'               "has skip() function"
assert_contains "$content" 'fails=$((fails + 1))' "increments fails counter"

begin_test "watchdog-script-no-awk"
content=$(cat "$SCRIPT")
assert_not_contains "$content" " awk " "no awk usage"

# ── Inventory coverage ────────────────────────────────────────────────────────

begin_test "watchdog-script-inventory"
inv="$REPO/memory/test-inventory.md"
assert_file_exists "$inv" "test-inventory.md exists"
assert_contains "$(cat "$inv")" "390_" "slot 390_ in inventory"

# ── Skip guard: absent device ─────────────────────────────────────────────────
# WATCHDOG_DEV=/nonexistent forces the device-absent skip path.
# Do NOT omit WATCHDOG_DEV here: writing to an actual /dev/watchdog on the CI host
# would arm the host watchdog timer.

begin_test "watchdog-script-skip-no-device"
out=$(WATCHDOG_DEV=/nonexistent/watchdog bash "$SCRIPT" 2>&1); rc=$?
assert_eq   "$rc" "0"    "exits 0 when device absent"
assert_contains "$out" "skip" "prints skip when device absent"
assert_not_contains "$out" "FAIL" "no FAIL when device absent"

# ── Exit 0 on CI host ─────────────────────────────────────────────────────────
# With WATCHDOG_DEV unset, the script uses real /dev/watchdog if present.
# On non-root CI: write fails → skip (not fail). On root CI: write succeeds → ok.
# Either way exit code must be 0 and no FAIL lines allowed.

begin_test "watchdog-script-exit0-on-host"
out=$(WATCHDOG_DEV=/nonexistent/watchdog bash "$SCRIPT" 2>&1); rc=$?
assert_eq "$rc" "0" "script exits 0 on CI host"
if printf '%s\n' "$out" | grep -q '^FAIL:'; then
    fail "script produced FAIL lines: $(printf '%s\n' "$out" | grep '^FAIL:')"
else
    pass "no FAIL lines in output"
fi

# ── Shellcheck POSIX sh compliance ───────────────────────────────────────────

begin_test "watchdog-script-shellcheck"
if ! command -v shellcheck &>/dev/null; then
    pass "skip: shellcheck not available"
else
    if shellcheck --shell=sh --severity=warning "$SCRIPT" >/dev/null 2>&1; then
        pass "shellcheck ok"
    else
        fail "shellcheck failed"
    fi
fi

finish
