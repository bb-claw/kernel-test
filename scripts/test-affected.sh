#!/bin/sh
# scripts/test-affected.sh — diff-aware wrapper for `make test-affected`.
# Mirrors shepherd SH-036 / healthy SH-037 pattern; adapted to kernel-test's
# framework-only CI test suite (`tests/ci/test-*.sh`).
#
# Full-run bailouts: Makefile, .github/workflows/**, lib/**, scripts/ci-*.sh,
# scripts/test-affected.sh itself.
#
# Opt-out: TEST_AFFECTED_BASE=<ref> env override.
#
# Usage:
#   scripts/test-affected.sh           # emit selection + run
#   scripts/test-affected.sh --list    # emit only

set -eu

mode=${1:-run}

base="${TEST_AFFECTED_BASE:-}"
if [ -z "$base" ]; then
  if git rev-parse --verify origin/dev >/dev/null 2>&1; then
    base=$(git merge-base HEAD origin/dev 2>/dev/null || git rev-parse origin/dev)
  elif git rev-parse --verify origin/main >/dev/null 2>&1; then
    base=$(git merge-base HEAD origin/main 2>/dev/null || git rev-parse origin/main)
  else
    base=HEAD
  fi
fi

{
  git diff --name-only "$base"...HEAD 2>/dev/null
  git diff --name-only
  git diff --cached --name-only
} | sort -u | grep -v '^$' > /tmp/kt-affected-changed.txt || true

FULL_RE='^(Makefile|\.github/workflows/|lib/|scripts/ci-.*\.sh$|scripts/test-affected\.sh$)'

if grep -Eq "$FULL_RE" /tmp/kt-affected-changed.txt; then
  echo "test-affected: full-run (diff touches build/workflow/lib surface)"
  tests=$(ls tests/ci/test-*.sh 2>/dev/null || true)
elif ! [ -s /tmp/kt-affected-changed.txt ]; then
  echo "test-affected: no changes vs $base — running full ci-test suite"
  tests=$(ls tests/ci/test-*.sh 2>/dev/null || true)
else
  rm -f /tmp/kt-affected-select.txt; touch /tmp/kt-affected-select.txt

  while IFS= read -r f; do
    case "$f" in
      tests/ci/test-*.sh)
        # Changed CI test → run it.
        echo "$f" >> /tmp/kt-affected-select.txt
        ;;
      tests/ci/lib.sh|tests/ci/fixtures/*)
        # Shared fixtures/lib → run everything in tests/ci.
        # shellcheck disable=SC2012
        ls tests/ci/test-*.sh 2>/dev/null >> /tmp/kt-affected-select.txt
        ;;
      tests/programs/*)
        # Changed program → run tests that reference it.
        prog=$(echo "$f" | sed -n 's|^tests/programs/\([^/]*\).*|\1|p')
        if [ -n "$prog" ]; then
          for t in tests/ci/test-*.sh; do
            grep -Fq "$prog" "$t" 2>/dev/null && echo "$t" >> /tmp/kt-affected-select.txt
          done
        fi
        ;;
      scripts/*.sh)
        # Changed non-ci script → run tests mentioning it.
        name=$(basename "$f" .sh)
        for t in tests/ci/test-*.sh; do
          grep -Fq "$name" "$t" 2>/dev/null && echo "$t" >> /tmp/kt-affected-select.txt
        done
        ;;
      docs/*|*.md)
        # Docs — safety net.
        # shellcheck disable=SC2012
        ls tests/ci/test-*.sh 2>/dev/null | head -2 >> /tmp/kt-affected-select.txt
        ;;
      *)
        # Unknown path — safety net.
        # shellcheck disable=SC2012
        ls tests/ci/test-*.sh 2>/dev/null | head -2 >> /tmp/kt-affected-select.txt
        ;;
    esac
  done < /tmp/kt-affected-changed.txt

  tests=$(sort -u /tmp/kt-affected-select.txt | grep -v '^$' || true)

  if [ -z "$tests" ]; then
    echo "test-affected: no mappable tests — running full suite"
    tests=$(ls tests/ci/test-*.sh 2>/dev/null || true)
  else
    n=$(printf '%s\n' "$tests" | wc -l | tr -d ' ')
    echo "test-affected: diff-aware ($n test(s) selected from diff)"
  fi
fi

printf '%s\n' "$tests" | sed 's/^/  /'

[ "$mode" = "--list" ] && exit 0

fail=0
for t in $tests; do
  echo "→ $t"
  if ! sh "$t"; then
    fail=$((fail + 1))
    echo "FAIL $t"
  fi
done

if [ "$fail" != 0 ]; then
  echo "test-affected: $fail failure(s)"
  exit 1
fi
echo "test-affected: all passed"
