#!/bin/bash
# Tier 2 test runner — run via: make ci-test
# Executes all tests/ci/test-*.sh and reports aggregate pass/fail.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pass_count=0
fail_count=0
failed_scripts=()

mapfile -t TEST_FILES < <(find "$REPO_ROOT/tests/ci" -name 'test-*.sh' | sort)

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    printf '[ci-test] no test files found in tests/ci/\n'
    exit 1
fi

printf '[ci-test] running %d test file(s)\n' "${#TEST_FILES[@]}"

for t in "${TEST_FILES[@]}"; do
    name=$(basename "$t")
    if bash "$t"; then
        (( pass_count++ )) || true
    else
        (( fail_count++ )) || true
        failed_scripts+=("$name")
    fi
done

printf '\n[ci-test] %d passed, %d failed\n' "$pass_count" "$fail_count"

if [[ $fail_count -gt 0 ]]; then
    printf '[ci-test] FAILED scripts:\n'
    for s in "${failed_scripts[@]}"; do
        printf '  %s\n' "$s"
    done
    exit 1
fi

printf '[ci-test] all tests passed\n'
