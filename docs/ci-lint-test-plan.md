# CI Plan — Tier 1 Lint + Tier 2 Harness Tests

Branch: `feat/ci-lint-test`
Start date: 2026-08-04

---

## Situation

The harness has local quality gates (shellcheck, test-inventory, memory size limits) enforced
by `.githooks/pre-push`.  These gates only fire when the developer has run `make hooks` and does
not bypass the hook.  PRs from forks or hook-bypassed pushes arrive unvalidated.

No CI exists today.  This plan adds two tiers without touching the kernel build or QEMU.

---

## Goals

1. **Tier 1 — `make lint`**: fast static checks that run on every push and PR; runnable locally
2. **Tier 2 — `make ci-test`**: fixture-based harness self-tests that run only when the scripts
   under test actually change
3. Single `.github/workflows/ci.yml` that calls both targets; no secrets required
4. No Telegram notifications (kept out of scope)
5. No kernel build, no QEMU, no cross-compilers — CI completes in under 2 minutes

---

## Tier 1 — `make lint`

### Checks

| Check | Tool | Scope |
|---|---|---|
| Shell syntax | `bash -n` | all tracked `*.sh` files |
| Static analysis (bash) | `shellcheck` (default mode) | all tracked `*.sh` except `tests/custom/` |
| Static analysis (Toybox/POSIX) | `shellcheck --shell=sh` | `tests/custom/*.sh` + `tests/001_smoke.sh` |
| Memory file sizes | `wc -l` | `memory/*.md` must be ≤ 150 lines |
| Test-inventory coverage | `grep` | every `tests/custom/*.sh` name in `memory/test-inventory.md` |
| Design doc present | `git ls-files` | feat/* and fix/* branches must have a `docs/*.md` |
| PR title format | regex | `<type>[(<scope>)]: <desc>` — CI only, skipped locally |

**Toybox rationale:** `tests/custom/` scripts target the Toybox sh POSIX subset, not bash.
`shellcheck --shell=sh` catches real bugs (unquoted expansions, non-POSIX constructs) without
false positives from bash-specific features like `[[`.

**Continue-on-error:** all checks run even when one fails so the developer sees all problems in
a single CI run.

**Local use:** `make lint` is fully runnable locally.  The PR-title check reads
`$GITHUB_EVENT_PATH` which is only set in CI; it is silently skipped when absent.

### Makefile target

```makefile
.PHONY: lint
lint:
	@bash scripts/ci-lint.sh
```

All check logic lives in `scripts/ci-lint.sh` (not inline YAML), consistent with the homelab
pattern (`make lint` → `make lint-context`).  CI calls `make lint`; developers call `make lint`.

---

## Tier 2 — `make ci-test`

### Naming

`make test` already runs the kernel VM tests.  Tier 2 uses `make ci-test` to avoid collision.

### Scope

Each script under test gets a dedicated test file.  Tests use only the standard library and
`bash`; no bats, no Python.

| Test file | Script under test | What is tested |
|---|---|---|
| `tests/ci/test-report.sh` | `lib/report.sh` | OVERALL logic (build/boot/kunit/shell/mismatch), kunit count format, build-only column, summary.txt, auto-commit |
| `tests/ci/test-diff.sh` | `lib/diff.sh` | PASS→FAIL regression detection, FAIL→PASS fix detection, same-label filter |
| `tests/ci/test-config-archive.sh` | `scripts/config-archive.sh` | archive filename naming, SHA256 dedup (passed wins), index format |
| `tests/ci/test-consolidate-index.sh` | `scripts/consolidate-index.sh` | SOURCE column, dedup by (source, SHA256), zero-sources graceful exit |
| `tests/ci/test-common.sh` | `lib/common.sh` | `arch_cross_compile`, `arch_kernel_image`, `arch_toybox_name`, `apply_arch_overlay` |
| `tests/ci/test-migrate-reports.sh` | `scripts/migrate-reports.sh` | dry-run output, `--apply` rename, baseline symlink update |
| `tests/ci/test-config-bisect.sh` | `scripts/config-bisect.sh` | candidate extraction: archived − tinyconfig+bootability baseline |
| `tests/ci/test-makefile-defaults.sh` | `Makefile` | `ARCHS_ALL`, `CONFIGS` default set, `DATA_REPO` default, `REPORT_DIR` default |
| `tests/ci/test-fetch.sh` | `lib/fetch.sh` | local-tag fallback when ls-remote fails, version written to `.kernel-version`, latest tag selection |
| `tests/ci/test-warnings.sh` | `lib/warnings.sh` | extraction, build-dir prefix stripping, FAIL-build skip, cross-arch divergence, between-run diff |
| `tests/ci/test-init-data-repo.sh` | `scripts/init-data-repo.sh` | directory creation, initial commit, idempotency, error on non-git existing path |

### Test helpers — `tests/ci/lib.sh`

```bash
assert_eq    <actual> <expected> [msg]
assert_ne    <actual> <expected> [msg]
assert_contains <haystack> <needle> [msg]
assert_not_contains <haystack> <needle> [msg]
assert_file_exists <path> [msg]
assert_exit0 <msg> <cmd...>
assert_exit1 <msg> <cmd...>
pass <msg>
fail <msg>
tmpdir              # sets $_LAST_TMPDIR, tracks for cleanup — never call via $()
setup_data_repo     # git-init temp repo; exports DATA_REPO and REPORT_DIR
setup_kernel_tree   # git-init temp kernel tree with version Makefile; exports KERNEL_TREE
setup_git_stub      # installs fake git that no-ops pull/push; exports PATH
teardown            # rm -rf all temp dirs; registered via trap EXIT
```

### Fixtures — `tests/ci/fixtures/`

Minimal synthetic data — no real kernel configs, no real report dirs.

```
tests/ci/fixtures/
  reports/
    mainline-7.2-2026-08-01_10-00-00-v7.2-rc1/
      build-tinyconfig-x86_64.status    PASS
      vm-tinyconfig-x86_64.status       PASS
      build-defconfig-x86_64.status     FAIL
    mainline-7.2-2026-08-02_10-00-00-v7.2-rc2/
      build-tinyconfig-x86_64.status    PASS
      vm-tinyconfig-x86_64.status       FAIL   ← regression
  configs/
    archive_failed/
      index.txt                         two entries; known SHA256s
  consolidation/
    local-mainline/
      archive_failed/index.txt
    hetzner-mainline/
      archive_failed/index.txt
```

### Env isolation

Each test creates its own `$TMPDIR`-rooted work dirs and exports `DATA_REPO=...` and
`KERNEL_TREE=...` before calling the script under test.  A `trap 'teardown' EXIT` cleans up
regardless of pass/fail.  No real `DATA_REPO` or kernel tree needed.

### Makefile target

```makefile
.PHONY: ci-test
ci-test:
	@bash scripts/ci-run-tests.sh
```

`scripts/ci-run-tests.sh` runs each `tests/ci/test-*.sh` in order, aggregates pass/fail counts,
and exits 1 if any test failed.

---

## CI Workflow — `.github/workflows/ci.yml`

### Triggers

```yaml
on:
  push:
    branches: ['feat/**', 'fix/**', 'chore/**', 'docs/**', 'refactor/**', 'test/**']
  pull_request:
    branches: [main]
```

### Concurrency

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Cancels stale runs when a new commit is pushed to the same branch.

### Jobs

```
detect-changes
  ├── outputs.docs_only   (only *.md changed → lint still runs; ci-test skipped)
  └── outputs.tier2       (lib/**, scripts/**, tests/ci/**, or Makefile changed)

lint (always)
  └── make lint           (all checks; continue-on-error per step)

ci-test (needs: lint, if tier2 == true)
  └── make ci-test
```

`docs_only` does not skip Tier 1 — shellcheck on a docs-only PR is a no-op but harmless; the
lint job always runs so the PR gets a green checkmark without special casing.

### Path filter for Tier 2

```yaml
- lib/**
- scripts/**
- tests/ci/**
- Makefile
```

### Runner

`ubuntu-latest` — `shellcheck` is pre-installed; no extra installs needed for Tier 1.
Tier 2 needs only `bash` and standard coreutils (also pre-installed).

---

## Files changed (scope)

### kernel-test/ (harness repo)

| File | Change |
|---|---|
| `.github/workflows/ci.yml` | New — CI workflow |
| `scripts/ci-lint.sh` | New — all Tier 1 check logic |
| `scripts/ci-run-tests.sh` | New — Tier 2 test runner |
| `tests/ci/lib.sh` | New — assert helpers + setup/teardown |
| `tests/ci/fixtures/` | New — synthetic fixture data |
| `tests/ci/test-report.sh` | New; extended with KUNIT_FAIL, TESTS_FAIL, MISMATCH, build-only, kunit format cases |
| `tests/ci/test-diff.sh` | New |
| `tests/ci/test-config-archive.sh` | New |
| `tests/ci/test-consolidate-index.sh` | New |
| `tests/ci/test-common.sh` | New |
| `tests/ci/test-migrate-reports.sh` | New |
| `tests/ci/test-config-bisect.sh` | New |
| `tests/ci/test-makefile-defaults.sh` | New |
| `tests/ci/test-fetch.sh` | New |
| `tests/ci/test-warnings.sh` | New |
| `tests/ci/test-init-data-repo.sh` | New |
| `Makefile` | Add `lint` and `ci-test` targets; update `.PHONY` and `help` |
| `CLAUDE.md` | Document `make lint`, `make ci-test`, `tests/ci/`, `scripts/ci-lint.sh` |
| `memory/workflows.md` | Add `make lint` and `make ci-test` sections |

---

## Verification checklist

1. `make lint` exits 0 on a clean branch
2. `make lint` exits non-zero and reports all failures when shellcheck, memory size, or
   inventory checks fail (introduce each deliberately)
3. `make ci-test` exits 0 with all tests passing
4. `make ci-test` exits non-zero and names the failing test when a fixture assertion fails
5. `make lint` runs cleanly locally on a non-feat/* branch (design-doc check gracefully skipped)
6. CI passes on a docs-only PR (lint runs, ci-test skipped)
7. CI runs ci-test when `lib/report.sh` is modified
8. CI skips ci-test when only `configs/*.config` is modified
9. A PR with a malformed title (e.g. `Update stuff`) fails the PR title check in CI

---

## Non-goals

- No Telegram notifications
- No kernel build or QEMU in CI
- No Tier 3 (pipeline smoke test) in this PR — separate branch
- No bats or Python test frameworks
- No CD or auto-merge (kernel-test has no staging environment)
