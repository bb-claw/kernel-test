# Plan: Regression Diff Between Report Runs

## Goal

Enable detection of behavioral changes (regressions and fixes) between two kernel
test runs by comparing per-test results stored in report directories.

## Design

### Data capture

`lib/report.sh` copies `build/<config>-<arch>/vm.status` into each report dir as
`vmstatus-<config>-<arch>.txt`. This makes every report dir self-contained and
diffable without needing the live `build/` tree.

### lib/diff.sh

Standalone script — also invoked automatically by `report.sh` at the end of each run.

- **Input:** two report dirs (OLD, NEW); optional output file path
- **Comparison per (config, arch):**
  - `BOOT`: PASS/FAIL change
  - `FAILED_TESTS`: per-test name set diff (PASS→FAIL = regression, FAIL→PASS = fix)
  - `TESTS_TOTAL`: inventory count change (test scripts added/removed)
  - KUnit: `KUNIT_FAIL` increase = regression, decrease = fix
- **Output:** regressions, fixes, unchanged count, overall summary
- **Exit code:** 0 = no regressions, 1 = regressions found (usable in scripts/CI)

### make diff

Explicit diff target. No args → auto-detect latest two runs in `reports/`.
`OLD=path NEW=path` → compare specific runs.

### make baseline

Creates `reports/baseline` symlink → latest run dir. `report.sh` auto-diffs
the current run against both the previous run AND the pinned baseline.

## Files changed

| File | Change |
|---|---|
| `lib/diff.sh` | New script |
| `lib/report.sh` | Copy vmstatus + invoke diff.sh at end |
| `Makefile` | `diff` and `baseline` targets |
