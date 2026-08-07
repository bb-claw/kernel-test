# tests/ci/

Harness self-tests — verify the pipeline scripts themselves without building
a kernel or running QEMU.  Run with `make ci-test`.

## How it works

`scripts/ci-run-tests.sh` executes every `test-*.sh` in this directory.
Each file is an independent bash script that sources `tests/ci/lib.sh` for
assertion helpers, runs its checks, and calls `finish` at the end.

## Assertion helpers (`lib.sh`)

| Helper | What it checks |
|---|---|
| `assert_eq A B msg` | A equals B (string) |
| `assert_contains text needle msg` | text contains needle |
| `assert_not_contains text needle msg` | text does not contain needle |
| `assert_file_exists path msg` | file exists |
| `pass msg` | record a passing assertion |
| `fail msg` | record a failing assertion |
| `begin_test name` | start a named test group |
| `finish` | print summary and exit 1 if any failure |
| `tmpdir` | create a temp dir; path in `$_LAST_TMPDIR`; auto-cleaned on exit |

## Test files

| File | What it covers |
|---|---|
| `test-arch-scripts.sh` | 370–410 VM test scripts: existence, shebang, boilerplate, no-awk, skip guards, shellcheck |
| `test-common.sh` | `lib/common.sh` shared functions: serial parser, status writer |
| `test-config-archive.sh` | `scripts/config-archive.sh` dedup + index logic |
| `test-config-bisect.sh` | `scripts/config-bisect.sh` candidate selection + resume |
| `test-consolidate-index.sh` | `scripts/consolidate-index.sh` merge logic |
| `test-diff.sh` | `lib/diff.sh` regression/fix detection |
| `test-fetch.sh` | `lib/fetch.sh` tag selection + fallback |
| `test-init-data-repo.sh` | `scripts/init-data-repo.sh` directory skeleton |
| `test-lint-context.sh` | `scripts/lint-context.sh` line-count enforcement |
| `test-makefile-defaults.sh` | Makefile variable defaults and exports |
| `test-migrate-reports.sh` | `scripts/migrate-reports.sh` rename logic |
| `test-ns-build.sh` | `tests/ns/` Makefile: all binaries built, correct names |
| `test-ns-configs.sh` | `configs/namespaces.config` fragment: all 8 namespace types present |
| `test-ns-initramfs.sh` | `lib/initramfs.sh` ns-binary injection path |
| `test-ns-scripts.sh` | 290–360 namespace VM scripts: structure + skip guards |
| `test-report.sh` | `lib/report.sh` HTML/text generation |
| `test-vm-parser.sh` | Serial output parser: PASS/FAIL counts, KUnit KTAP, canary |
| `test-warnings.sh` | `lib/warnings.sh` extraction + diff logic |

## Fixtures (`fixtures/`)

Static input data used by the tests — no kernel tree, no QEMU output needed.
See `fixtures/README.md` for the layout.

## Adding a CI test

1. Create `tests/ci/test-<feature>.sh`
2. Source `lib.sh` at the top: `. "$REPO/tests/ci/lib.sh"`
3. Use `begin_test` / assertion helpers / `finish`
4. Add a row to the table above

Every new script, config, or binary added to the harness must have a
corresponding CI test (enforced by memory rule in `memory/feedback_feature_ci_tests.md`).
