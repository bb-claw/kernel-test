#!/bin/bash
# Static checks for Toybox sh pitfalls in tests/custom/*.sh and tests/001_smoke.sh.
# These patterns cause silent misbehaviour under Toybox 0.8.9+ (VM test environment)
# but are not caught by shellcheck (which targets bash/POSIX sh, not Toybox quirks).
# See memory/code-quality.md for the full pitfall list.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

# Collect all VM test scripts (tests/001_smoke.sh + tests/custom/*.sh).
mapfile -t ALL_SCRIPTS < <(
    find "$REPO/tests/custom" -name '*.sh' | sort
    [[ -f "$REPO/tests/001_smoke.sh" ]] && printf '%s\n' "$REPO/tests/001_smoke.sh"
)

# ── elif ban ─────────────────────────────────────────────────────────────────
# Toybox 0.8.9 bug: when the 'if' condition is true, the 'else' body also
# executes. Any 'elif' in a test script is a latent double-execution bug.
# Use nested if/else/fi instead.

begin_test "no-elif-in-test-scripts"
elif_hits=()
for s in "${ALL_SCRIPTS[@]}"; do
    # Exclude comment lines (first non-whitespace char is #) before checking.
    if grep -v $'^[[:space:]]*#' "$s" 2>/dev/null | grep -q $'^[[:space:]]*elif'; then
        elif_hits+=("$(basename "$s")")
    fi
done
if [[ ${#elif_hits[@]} -eq 0 ]]; then
    pass "no elif in any test script"
else
    for h in "${elif_hits[@]}"; do
        fail "elif found in $h — use nested if/else/fi (Toybox 0.8.9 double-execution bug)"
    done
fi

# ── leading-underscore variable ban ──────────────────────────────────────────
# Toybox sh parses '$_name' as '$_' (last-arg special var) concatenated with
# the literal string 'name'. Variables whose names start with _ must not be
# referenced with '$_name' syntax.

begin_test "no-leading-underscore-var-expansion"
underscore_hits=()
for s in "${ALL_SCRIPTS[@]}"; do
    # Exclude comment lines before checking; match $_ followed by a letter/digit.
    if grep -v $'^[[:space:]]*#' "$s" 2>/dev/null | grep -qE '\$_[a-zA-Z0-9]'; then
        underscore_hits+=("$(basename "$s")")
    fi
done
if [[ ${#underscore_hits[@]} -eq 0 ]]; then
    pass "no \$_varname in any test script"
else
    for h in "${underscore_hits[@]}"; do
        fail "\$_varname found in $h — Toybox parses as \$_ + literal (rename the variable)"
    done
fi

# ── bare 'sh' before '-c' ban ─────────────────────────────────────────────────
# 'sh' (bare name) is a NOFORK builtin in Toybox 0.8.11+. It runs the command
# via longjmp in the same process — no fork/exec occurs. Always use '/bin/sh'
# (full path with a '/') to force fork+exec.

begin_test "no-bare-sh-c-in-test-scripts"
sh_hits=()
for s in "${ALL_SCRIPTS[@]}"; do
    # Exclude comment lines, then detect 'sh -c' not preceded by '/' (i.e. not /bin/sh -c).
    # The pattern '[^/]sh -c' catches ' sh -c' and '^sh -c' but not '/bin/sh -c'.
    # A leading-space guard handles the line-start case via the two alternatives below.
    non_comment=$(grep -v $'^[[:space:]]*#' "$s" 2>/dev/null) || true
    if printf '%s\n' "$non_comment" | grep -qE '(^|[^/a-zA-Z0-9_])sh -c'; then
        # Verify it's not all /bin/sh -c occurrences (exclude lines that only have /bin/sh -c)
        if printf '%s\n' "$non_comment" | grep -E '(^|[^/a-zA-Z0-9_])sh -c' \
                | grep -qv '/bin/sh -c'; then
            sh_hits+=("$(basename "$s")")
        fi
    fi
done
if [[ ${#sh_hits[@]} -eq 0 ]]; then
    pass "no bare 'sh -c' in any test script"
else
    for h in "${sh_hits[@]}"; do
        fail "bare 'sh -c' found in $h — use '/bin/sh -c' to force fork+exec (Toybox NOFORK)"
    done
fi

finish
