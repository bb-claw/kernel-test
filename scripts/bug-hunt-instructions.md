# Bug Hunt — Claude Code Instructions

## Task

Find **3 high-severity bugs** in this `kernel-test` repository. Stop the moment you
have confirmed 3 bugs. Do not modify any files — search and report only.

## Repository Context

A Bash harness that builds Linux release-candidate kernels under multiple config profiles,
boots them in QEMU/KVM with a minimal Toybox initramfs, runs shell test scripts inside
the VM, and produces an HTML+text report for LKML submission.

Key files to examine:
- `lib/build.sh` — cross-compile kernel per (config × arch); writes `build/<cfg>-<arch>/build.status`
- `lib/common.sh` — `parse_serial_output()`: parse raw QEMU serial → PASS/FAIL/KUnit counts
- `lib/vm.sh` — launch QEMU; capture serial to `dmesg.txt`
- `lib/report.sh` — aggregate `build.status` + `vm.status` → `summary.html` + `summary.txt`
- `lib/diff.sh` — compare two report directories for per-test regressions
- `lib/initramfs.sh` — build Toybox cpio initramfs; inject test scripts; write `/init`
- `scripts/dev-test.sh` — branch gate: fixed-core CI runs + random VM combos
- `tests/custom/*.sh` — VM test scripts (run under Toybox sh 0.8.14, POSIX only)
- `tests/ci/test-*.sh` — host-side CI tests (Bash; no kernel/QEMU needed)
- `memory/code-quality.md` — full pitfall list; read this first for context
- `FINDINGS.md` — past bugs found in production; read for recurring patterns

## Already Covered — Do Not Duplicate

These patterns are already caught by existing CI checks:

| Pattern | Caught by |
|---|---|
| `elif` in VM test scripts | `test-toybox-pitfalls.sh` |
| `$_varname` in VM test scripts | `test-toybox-pitfalls.sh` |
| bare `sh -c` (NOFORK) in VM test scripts | `test-toybox-pitfalls.sh` |
| `var=$(cmd) \|\| fallback` in VM test scripts | `test-static-analysis.sh` check 1 |
| `total_paths` / `coverage-map.md` row-count drift | `test-static-analysis.sh` check 2 |
| ci9_tests missing a fixed-core entry | `test-static-analysis.sh` check 3 |
| `build.sh` missing STATUS sentinel before early die | `test-static-analysis.sh` check 4 |
| `FAILED_TESTS` pipeline missing `\r` stripping | `test-static-analysis.sh` check 5 |

## Severity Criteria

Target **HIGH** severity only:
- **Silent false result**: test reports PASS when it should FAIL (or vice versa)
- **Data corruption**: `vm.status`, `build.status`, or report files contain wrong data
- **Stale state**: output from a prior run silently persists into the current run's result
- **Wrong assumption**: script assumes tool/kernel/shell behaviour that is incorrect,
  causing consistent wrong results across all runs

Skip: cosmetic issues, style problems, minor inefficiency, documentation gaps.

## Systematic Search Areas

**1. `lib/common.sh` — serial output parsing**
Focus on `parse_serial_output()`. Check every grep/sed pipeline that processes raw dmesg.
Look for: variables not reset between calls, grep that fails under `set -e` (no `|| true`
or `2>/dev/null`), off-by-one in line counting, edge cases where output is empty.

**2. `lib/report.sh` — status aggregation**
Check how it reads `vm.status` and `build.status` field by field. Look for: missing default
when a key is absent (causes wrong OVERALL), stale variable from a prior loop iteration
bleeding into the next config's row, wrong exit code decision.

**3. `lib/diff.sh` — regression comparison**
Check how it parses saved `vmstatus-<cfg>-<arch>.txt` files. Look for: `\r` in test names
causing silent comparison failures, grep anchor missing, field extraction wrong for configs
with spaces or special characters.

**4. `lib/vm.sh` — QEMU management**
Check exit code handling for `timeout`-wrapped QEMU. Look for: exit code 124 (timeout) vs
non-zero test failure conflated, serial capture file not truncated/cleared before use,
KUnit detection logic that silently skips when ANSI escape stripping fails.

**5. `lib/initramfs.sh` — initramfs and `/init` construction**
Check the generated `/init` script. Look for: bare `sh` (not `/bin/sh`) for test script
invocation, protocol markers (`TEST PASS`, `TEST FAIL`) written to buffered stdout instead
of `/dev/console`, test scripts injected without executable bit.

**6. `tests/custom/*.sh` — VM test scripts (Toybox sh)**
Beyond patterns already caught, look for: `awk` or `tr` (not in Toybox binary), `[[ ]]`
(not POSIX sh), `$(( ))` in a while loop (OOM in 512 MB VM), `dd` with key=value args
(Toybox ignores them), multi-line `[ ]` string comparison (Toybox bug).

**7. `tests/ci/test-*.sh` — CI test correctness**
Look for: fixture-based tests that assume a fixed line number or field position that could
shift if the tested script is refactored, grep patterns that are too broad and match
unintended lines, missing `|| true` on commands that legitimately return non-zero.

## Output Format

Write exactly one section per bug, using this template:

    ## BUG-N — Short Title (HIGH)

    **File**: `path/to/file.sh:line`

    **Root cause**: One sentence identifying the specific defect.

    **Impact**: What fails or produces wrong output, and under which conditions.

    **Mitigation**:
    Minimal code change that fixes the root cause.

    **Test coverage**: A specific grep pattern or structural invariant that a new
    CI check could use to prevent regression.

After the third bug, write exactly this line and then stop:

    SEARCH COMPLETE: 3 bugs found.

## Time Budget

Work efficiently — read key files first, then grep for patterns. If you reach 26 minutes
without 3 confirmed bugs, write what you have and end with:

    SEARCH STOPPED: time limit reached. N bug(s) found.
