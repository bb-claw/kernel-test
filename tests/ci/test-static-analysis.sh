#!/bin/bash
# Static bug-hunt checks not covered by existing CI tests.
# Detects: dead Toybox sh skip guards, dev-test/coverage-map drift,
# and build.sh stale-status sentinel absence.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# ── Check 1: dead var=$(cmd) || guard in VM test scripts ─────────────────────
# Toybox sh bug: variable assignment always exits 0 — the || branch never fires.
# Pattern: <name>=$(cmd) || { ... } on the same line.
# Legitimate uses of || INSIDE $() (e.g. val=$(cmd || echo 0)) are excluded.
# Only flags cases where || appears AFTER the closing ) of the substitution.

begin_test "no-dead-assignment-guard-in-test-scripts"

mapfile -t ALL_SCRIPTS < <(
    find "$REPO/tests/custom" -name '*.sh' | sort
    [[ -f "$REPO/tests/001_smoke.sh" ]] && printf '%s\n' "$REPO/tests/001_smoke.sh"
)

dead_guard_hits=()
for s in "${ALL_SCRIPTS[@]}"; do
    # Exclude comment lines, then look for: word=$(...)  ||
    # The pattern after the closing ) must be || (not inside the substitution).
    # Simplified: find lines matching /[a-z_]+=\$(...) *||/ where ) closes the subshell.
    if grep -v $'^[[:space:]]*#' "$s" 2>/dev/null \
            | grep -qE '^[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*=\$\([^)]*\)[[:space:]]*\|\|'; then
        dead_guard_hits+=("$(basename "$s")")
    fi
done

if [[ ${#dead_guard_hits[@]} -eq 0 ]]; then
    pass "no dead var=\$(cmd) || guard in test scripts"
else
    for h in "${dead_guard_hits[@]}"; do
        fail "dead assignment guard in $h: var=\$(cmd) || fallback — Toybox sh assigns 0 exit, || never fires; use file redirect instead"
    done
fi

# ── Check 2: dev-test total_paths matches coverage-map.md row count ──────────
# Each path row in coverage-map.md starts with "| [A-Z][0-9]".
# total_paths= in dev-test.sh must equal this count.

begin_test "dev-test-total-paths-matches-coverage-map"

map_count=$(grep -c $'^| [A-Z][0-9]' "$REPO/tests/ci/coverage-map.md" || true)
script_val=$(grep -oP '(?<=^total_paths=)\d+' "$REPO/scripts/dev-test.sh" || true)

if [[ -z $script_val ]]; then
    fail "total_paths not found in scripts/dev-test.sh"
elif [[ $script_val -eq $map_count ]]; then
    pass "total_paths=$script_val matches coverage-map.md ($map_count rows)"
else
    fail "total_paths=$script_val in dev-test.sh but coverage-map.md has $map_count rows — update total_paths"
fi

# ── Check 3: every "fixed core via C9" path has a ci9_tests entry ────────────
# coverage-map.md rows with "fixed core via C9 (test-FOO.sh)" must have
# a matching "XX:test-FOO.sh" entry in the ci9_tests array in dev-test.sh.

begin_test "dev-test-ci9-covers-all-fixed-core-c9-paths"

mapfile -t c9_map_scripts < <(
    grep -oP 'fixed core via C9 \(test-[a-z_-]+\.sh\)' \
        "$REPO/tests/ci/coverage-map.md" \
    | grep -oP 'test-[a-z_-]+\.sh' || true
)

missing_c9=()
for script in "${c9_map_scripts[@]}"; do
    if ! grep -qF "\"${script}\"" "$REPO/scripts/dev-test.sh" 2>/dev/null \
       && ! grep -qP ":${script//./\\.}" "$REPO/scripts/dev-test.sh" 2>/dev/null; then
        missing_c9+=("$script")
    fi
done

if [[ ${#missing_c9[@]} -eq 0 ]]; then
    pass "all fixed-core C9 paths have ci9_tests entries (${#c9_map_scripts[@]} checked)"
else
    for m in "${missing_c9[@]}"; do
        fail "fixed-core C9 path $m listed in coverage-map.md but missing from ci9_tests[] in dev-test.sh"
    done
fi

# ── Check 4: build.sh writes/clears build.status before early die calls ──────
# After "mkdir -p \"\$OUT_DIR\"", every die() call that can fire before the
# first explicit STATUS= write must be preceded by a sentinel write to STATUS_FILE.
# We check the simpler invariant: STATUS_FILE has a write (printf/: >) before
# the ccache die line.

begin_test "build-sh-status-sentinel-before-ccache-die"

build_sh="$REPO/lib/build.sh"
# Extract line numbers for key events
mkdir_line=$(grep -n 'mkdir -p "\$OUT_DIR"' "$build_sh" | head -1 | cut -d: -f1)
ccache_die_line=$(grep -n 'die "ccache not found' "$build_sh" | head -1 | cut -d: -f1)
sentinel_line=$(grep -n 'STATUS=INFRA_FAIL\|> "\$STATUS_FILE"\|printf.*STATUS.*> "\$STATUS_FILE"' \
    "$build_sh" | awk -F: -v m="$mkdir_line" '$1 > m {print $1; exit}' || true)

if [[ -z $mkdir_line || -z $ccache_die_line ]]; then
    fail "build.sh: could not find mkdir OUT_DIR or ccache die line — structure changed"
elif [[ -z $sentinel_line ]]; then
    fail "build.sh: no STATUS_FILE sentinel write found between mkdir \$OUT_DIR (line $mkdir_line) and ccache die (line $ccache_die_line) — stale build.status risk"
elif [[ $sentinel_line -lt $ccache_die_line ]]; then
    pass "build.sh: STATUS_FILE sentinel at line $sentinel_line precedes ccache die at line $ccache_die_line"
else
    fail "build.sh: STATUS_FILE sentinel at line $sentinel_line is AFTER ccache die at line $ccache_die_line"
fi

finish
