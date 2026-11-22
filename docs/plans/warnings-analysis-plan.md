# Warnings Analysis — Plan

Branch: `feat/warnings-analysis`
Start date: 2026-07-28

---

## Situation

The harness already builds kernels across 4 architectures and 9 config profiles on every RC.
All compiler output lands in `build/<config>-<arch>/build.log`, but nothing reads those logs
for warnings — only build failures (STATUS=FAIL) are surfaced in the report. Compiler warnings
that don't break the build are invisible, including cross-architecture assumption bugs that appear
on arm64/i386 but not x86_64.

---

## Problems to Solve

1. **Silent warning regressions** — a new `-Warray-bounds` or `-Wimplicit-int` warning introduced
   between RC3 and RC4 is not surfaced; it only becomes visible if a future GCC version promotes
   it to an error.
2. **Cross-arch divergence is undetected** — warnings present on arm64/i386 but absent on x86_64
   almost always indicate real architecture assumption bugs (wrong `sizeof`, endianness, alignment),
   but nothing currently flags them.
3. **No between-run comparison** — there is no way to see which warnings are new in the current
   RC vs the previous one without manually diffing large log files.

---

## Goals

1. `make warnings` runs standalone (post-hoc on existing build logs) and writes
   `warnings-summary.txt` + per-combo `warnings-<config>-<arch>.txt` to the latest report dir.
2. `report.sh` calls `lib/warnings.sh` automatically at the end of every `make all` run.
3. `warnings-summary.txt` shows: counts table, NEW SINCE PREV RUN section, CROSS-ARCH DIVERGENCE
   section (warnings on non-x86_64 absent from x86_64 for the same config).
4. Auto-diff vs previous same-label run writes `warnings-diff-prev.txt` to the report dir.
5. `make warnings-baseline` pins a `reports/warnings-baseline` symlink; future runs write
   `warnings-diff-baseline.txt`.
6. OVERALL pass/fail is unaffected — warnings are informational only.

---

## Scope

Files changed:
- `lib/warnings.sh` — new; core extraction + summary + diff logic
- `lib/report.sh` — call `lib/warnings.sh` at the end (after existing diff calls)
- `Makefile` — add `warnings` and `warnings-baseline` targets

No changes to: `lib/diff.sh`, `lib/vm.sh`, `lib/build.sh`, `summary.html`, `summary.txt`,
`summary.mail.txt`, OVERALL exit code, `vmstatus` files, test scripts.

---

## Non-goals

- Including warnings in `summary.mail.txt` or LKML submission text (manual curation preferred).
- Failing the build on new warnings (`OVERALL=FAIL` trigger).
- Sparse / smatch / `W=1` analysis (separate concern; different invocation).
- Capturing `error:` lines from failed builds (already surfaced via STATUS=FAIL in report).
- Deduplication of near-duplicate warnings (exact match only; line-number churn is acceptable noise).

---

## Design decisions

### Auto-run vs explicit invocation

Auto-run: `report.sh` calls `lib/warnings.sh` at the end. This mirrors how `report.sh` already
calls `lib/diff.sh`. `make warnings` also works standalone against existing `build/` logs, writing
to the latest report dir (identified the same way `report.sh` finds the latest run).

`NO_WARNINGS=1` is not added — warnings extraction is fast (just greps) and adds no meaningful
overhead.

### Warning extraction scope

Extract all lines matching `: warning:` from `build/<config>-<arch>/build.log`.
Only process combos where `build/<config>-<arch>/build.status` contains `STATUS=PASS`.
Rationale: warnings from failed builds are dominated by cascading errors; the signal is low.

Strip the absolute build directory prefix from file paths so warnings are repo-relative:
`/home/user/build/defconfig-x86_64/drivers/net/foo.c:42:` → `drivers/net/foo.c:42:`.
This makes cross-run diffs stable regardless of host path.

### Cross-arch divergence detection

x86_64 is the baseline. For each config, compare the warning set of each non-x86_64 arch
(arm64, i386, riscv) against the x86_64 warning set for the same config.
A warning is flagged as "divergent" if:
- It appears in at least one non-x86_64 arch, AND
- It does NOT appear in x86_64 for the same config.

Only the warning text + file + line is compared (not the arch). The divergence section lists
which arches the warning appears in and that it is absent from x86_64.

### Between-run diff

Same auto-detect logic as `lib/diff.sh`: scan `reports/` for the two most recent runs with
the same label, compare per-combo `warnings-<config>-<arch>.txt` files.

NEW warnings = lines in current run absent from previous run.
FIXED warnings = lines in previous run absent from current run.

Exact-match comparison on the full `file:line: warning: msg` string.
Output: `warnings-diff-prev.txt` in the report dir.

### Baseline support

`make warnings-baseline` sets `reports/warnings-baseline` symlink to the latest report dir
(same pattern as `make baseline` which sets `reports/baseline`).
`lib/warnings.sh` auto-diffs vs `reports/warnings-baseline` when the symlink exists,
writing `warnings-diff-baseline.txt`.

### Output format — warnings-summary.txt

```
=== Warning Summary: <label>-<version> ===

Counts (warnings per combo):
  defconfig-x86_64:  12   defconfig-arm64:  18   defconfig-i386:  21   defconfig-riscv:   9
  tinyconfig-x86_64:  3   tinyconfig-arm64:   5   tinyconfig-i386:   7  tinyconfig-riscv:  2
  ...

NEW SINCE <prev-label> (N warnings):
  drivers/net/foo.c:42: defconfig-arm64: warning: array subscript above bounds [-Warray-bounds]
  drivers/clk/bar.c:17: tinyconfig-i386: warning: implicit conversion [-Wimplicit-int]

FIXED SINCE <prev-label> (N warnings):
  ...

CROSS-ARCH DIVERGENCE (present on non-x86_64 only, N warnings):
  [defconfig]
    drivers/net/foo.c:42  arm64 i386  (not x86_64)
      warning: array subscript 'i' is above array bounds [-Warray-bounds]

  [tinyconfig]
    ...

(no previous run found)   <- when no prev run exists
```

### Per-combo files — warnings-<config>-<arch>.txt

One warning per line, sorted, deduplicated:
```
drivers/clk/bar.c:17: warning: implicit conversion loses integer precision [-Wimplicit-int]
drivers/net/foo.c:42: warning: array subscript 'i' is above array bounds [-Warray-bounds]
```

Stored in the report dir alongside `vmstatus-<config>-<arch>.txt`.
Used as the basis for between-run diffs and divergence detection.

---

## Testing strategy

- **Correctness** — run `make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS="x86_64 arm64"`, confirm
  `warnings-summary.txt` appears in the report dir and contains the three sections.
- **Standalone target** — run `make warnings` without a fresh build, confirm it reads existing
  `build/` logs and writes to the latest report dir.
- **Baseline** — run `make warnings-baseline`, confirm symlink created; run `make all` again,
  confirm `warnings-diff-baseline.txt` appears.
- **No OVERALL impact** — confirm `summary.txt` OVERALL is unchanged when warnings are present.
- **Empty build** — confirm graceful output ("no warnings found") when all build logs are clean.

---

## Testing commands

```sh
# 1. Full run — warnings auto-generated
make all NO_FETCH=1 CONFIGS="tinyconfig defconfig" ARCHS="x86_64 arm64 i386"
# Expected: warnings-summary.txt in latest report dir; OVERALL unchanged

# 2. Standalone target
make warnings
# Expected: re-reads build/ logs, updates warnings-summary.txt in latest report dir

# 3. Baseline pin + diff
make warnings-baseline
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64
# Expected: warnings-diff-baseline.txt in new report dir

# 4. Cross-arch divergence visible
grep -A3 "CROSS-ARCH DIVERGENCE" reports/$(ls -t reports/ | head -1)/warnings-summary.txt

# 5. No OVERALL regression
grep "^OVERALL" reports/$(ls -t reports/ | head -1)/summary.txt
# Expected: same as without warnings
```
