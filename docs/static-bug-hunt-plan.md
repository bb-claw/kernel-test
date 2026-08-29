# feat: static bug-hunt tool — Plan

Branch: `feat/static-bug-hunt`
Start date: 2026-08-28

---

## Situation

A systematic static analysis pass was run across the repository to find high-severity
bugs not caught by existing CI tests. Three bugs were found: two in test scripts /
gate infrastructure, one in a lib script. All three cause incorrect results in ways
that are silent and recurring.

---

## Bugs Found

### BUG-1 — `030_check-dmesg.sh`: dead skip guard (HIGH)

**Pattern**: `KLOG=$(dmesg 2>/dev/null) || { skip "dmesg not readable"; exit 0; }`

**Root cause**: Toybox sh 0.8.9 bug — a variable assignment (`var=$(cmd)`) always
exits 0 regardless of the command's exit code. The `||` branch never fires.

**Impact**: If `dmesg` fails inside the VM, `KLOG` is empty. All three grep checks
(`BUG:`, `Oops:`, `WARNING:`) trivially report "no issues" — false passes. The test
then FAILs on the "Linux version" check rather than skipping cleanly. Any kernel
BUG or Oops that happened before dmesg failed would be silently missed.

**Mitigation**: Redirect dmesg to a temp file; check file size to detect failure:
```sh
dmesg > /tmp/klog.txt 2>/dev/null
if [ ! -s /tmp/klog.txt ]; then skip "dmesg produced no output"; exit 0; fi
KLOG=$(cat /tmp/klog.txt)
```

**Test coverage**: `test-static-analysis.sh` checks all test scripts for the
`var=$(cmd) || fallback` pattern (undocumented Toybox pitfall, not in existing
`test-toybox-pitfalls.sh`).

---

### BUG-2 — `scripts/dev-test.sh`: missing G2 path + stale `total_paths` (HIGH)

**Root cause A**: `test-toybox-pitfalls.sh` (G2) was added to `coverage-map.md` as
a fixed-core path in the `feat/pipe-elif-cr-nofork` branch, but was not added to
the `ci9_tests[]` array in `scripts/dev-test.sh`. G2 is never exercised by
`make dev-test`.

**Root cause B**: `total_paths=36` in dev-test.sh is stale. The coverage map now
has 40 entries. The wrong denominator inflates reported coverage: `28/36 = 77%`
instead of the correct `28/40 = 70%`. The gate check is `pct -gt 70` (strict), so
with the correct denominator, fixed-core coverage is exactly 70% — which FAILS.
The stale value masks this.

**Impact**:
1. A contributor can add `elif`/`$_varname`/bare `sh -c` to a test script, run
   `make dev-test` (passes), and push — `test-toybox-pitfalls.sh` only runs on
   `make ci-test` (GitHub Actions).
2. The coverage percentage displayed is wrong; the gate threshold is miscalibrated.

**Mitigation**: Add `"G2:test-toybox-pitfalls.sh"` to `ci9_tests[]`; set
`total_paths=40`; fix coverage-map.md header to "40 functional decision paths".

**Test coverage**: `test-static-analysis.sh` verifies that `total_paths` in
dev-test.sh matches the row count in coverage-map.md, and that every path marked
"fixed core via C9" has a corresponding entry in `ci9_tests[]`.

---

### BUG-3 — `lib/build.sh`: stale `build.status` after early `die` (MEDIUM)

**Root cause**: `build.sh` clears `vm.status` at line 51 (`rm -f "$OUT_DIR/vm.status"`)
but never clears `build.status`. The `command -v ccache || die "..."` guard at line
62 fires AFTER `mkdir -p "$OUT_DIR"`, so any existing `build.status` from a previous
run survives. `report.sh` reads this stale file and reports the old STATUS=PASS.

**Scenario**: Previous run succeeds (STATUS=PASS in build.status). ccache is then
removed. Next `make all` → build.sh dies at ccache check → vm.status cleared,
build.status not cleared → report.sh reads STATUS=PASS → false PASS in report.

**Impact**: False PASS report for a build that never ran. LKML-sent summary.mail.txt
would report PASS for that config/arch combination.

**Mitigation**: Write a sentinel to `build.status` immediately after the directory
is created, before any early-exit guards:
```bash
mkdir -p "$OUT_DIR"
: > "$LOG_FILE"
rm -f "$OUT_DIR/vm.status"
printf 'STATUS=INFRA_FAIL\n' > "$STATUS_FILE"   # cleared if build succeeds
```

**Test coverage**: `test-static-analysis.sh` checks that `build.sh` writes
`build.status` before any `die` call that follows `mkdir -p "$OUT_DIR"`.

---

## Tool Design: `tests/ci/test-static-analysis.sh`

A new Tier 2 CI test that runs five static checks not covered by existing tests:

1. **Dead-guard check**: scan all VM test scripts for `var=$(cmd) || fallback`
   where the `||` would be silently swallowed by the Toybox sh assignment bug.

2. **Coverage-map consistency**: verify that `total_paths` in `dev-test.sh`
   equals the number of rows in `coverage-map.md`, and that every "fixed core
   via C9" entry has a matching entry in `ci9_tests[]`.

3. **Build-status sentinel check**: verify that `build.sh` writes `build.status`
   (or explicitly clears it) before any `die` that follows `mkdir -p "$OUT_DIR"`.

4. **`\r` stripping check**: verify that the `FAILED_TESTS` extraction pipeline
   in `lib/common.sh` includes `sed 's/\r//'` — QEMU serial uses `\r\n` and
   without stripping, test names in `vm.status` and LKML reports are corrupted
   (FINDINGS.md 2026-08-26).

---

## Scope

Files changed:
- `tests/ci/test-static-analysis.sh` — new CI test (the bug-hunt tool)
- `tests/custom/030_check-dmesg.sh` — fix dead skip guard (BUG-1)
- `scripts/dev-test.sh` — add G2 to ci9_tests, fix total_paths (BUG-2)
- `tests/ci/coverage-map.md` — fix header count (BUG-2 docs)
- `lib/build.sh` — write STATUS=INFRA_FAIL sentinel before early die (BUG-3)
- `tests/ci/coverage-map.md` — add G3 row for test-static-analysis.sh
- `scripts/dev-test.sh` — add G3 to ci9_tests, increment total_paths
- `memory/code-quality.md` — document `var=$(cmd) || fallback` Toybox pitfall

---

## Non-goals

- Fixing all occurrences of `var=$(cmd) ||` in lib/ scripts (bash, not Toybox sh;
  bash assignments do preserve exit codes)
- Checking coverage of paths D4/D5/D6 (board hardware; always pool-only)

---

## Testing strategy

- **BUG-1**: `test-static-analysis.sh` check 1 catches any `var=$(cmd) || x`
  in test scripts. After fix, grep confirms the file uses the temp-file pattern.
- **BUG-2**: After fix, `make dev-test` displays "paths=29/41" (with G2+G3 added);
  `test-toybox-pitfalls.sh` is run and its result appears in dev-test output.
- **BUG-3**: After fix, if ccache is removed, `build.status` shows STATUS=INFRA_FAIL
  rather than a stale STATUS=PASS.

```sh
make ci-test     # must pass including test-static-analysis.sh
make dev-test    # paths count must match coverage-map.md total_paths
```
