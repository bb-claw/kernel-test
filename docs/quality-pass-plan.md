# Quality Pass — Plan

Branch: `feat/quality-pass`
Status: **complete**

---

## Goals

1. Raise `make dev-test` fixed-core path coverage from 74% (32/43) to >80%.
2. Fix `build.sh` error-path correctness: early `die()` calls before `STATUS=INFRA_FAIL` write leave stale `STATUS=PASS`.
3. New CI test suite covering build.sh failure modes (I1–I3).
4. Normalize all pipeline output to the standard `HH:MM:SS [elapsed] config arch INFO  message` format.

---

## Audit Findings and Fixes

### 1 — build.sh early `die()` before INFRA_FAIL (bug — fixed)

Three validation `die()` calls (bad arch, missing kernel tree, missing GCC) fired before
`mkdir -p` and `STATUS=INFRA_FAIL` write. On a repeat run with an existing build dir the
stale `STATUS=PASS` from the prior run survived.

**Fix:** Moved `OUT_DIR` assignment, `mkdir -p`, log creation, `rm -f vm.status`, and
`STATUS=INFRA_FAIL` write to before the validation block.

### 2 — A4/A7 not credited in fixed CI core (coverage gap — fixed)

A4 (Build FAIL → report shows FAIL) and A7 (BOOT=FAIL when TEST_DONE absent) were
covered by existing `test-report.sh` and `test-vm-parser.sh` but `cover A4 A7` was never
called. Promoted to fixed-core by adding them to the C3 cover call.

### 3 — Programs/ns build output format inconsistency (fixed)

`tests/common.mk` and `tests/ns/Makefile` printed bare `[ns] riscv ns-time` lines
(no timestamp, no `INFO`) and leaked full compiler command lines at V=0. Makefile
`Entering/Leaving directory` noise interleaved between pipeline phases.

**Fix:**
- Compiler invocations prefixed with `$(Q)` — silent at default V=0, shown at V=1.
- Per-binary summary lines changed from `@printf '[tag] ...'` to `@bash lib/mklog.sh '[tag] ...'`.
- `mklog.sh` changed from `log()` to `info()` — all orchestration headers now carry `INFO`.
- `preflight.sh` converted from bare `printf 'Preflight: ...'` to `info()`/`warn()`.
- `MAKEFLAGS += --no-print-directory` added to root Makefile — eliminates all
  `make[N]: Entering/Leaving directory` noise at every recursion level.
- `tests/programs/Makefile` uses `--no-print-directory --silent` on sub-makes to
  suppress "Nothing to be done" messages during no-op rebuilds.

### 4 — Makefile hw-deploy/install bare printf (deferred)

`hw-deploy` and `install` targets use direct `printf` instead of `lib/mklog.sh`.
Deferred — only visible during hw targets, not `make all`.

---

## New CI Paths (coverage-map additions)

| ID | Description | Covering scenario |
|---|---|---|
| I1 | build.sh bad arch: exits non-zero, INFRA_FAIL written before die() — stale PASS overwritten | test-build-errors.sh |
| I2 | build.sh missing kernel tree: exits non-zero, INFRA_FAIL written before die() | test-build-errors.sh |
| I3 | build.sh missing GCC: exits non-zero, INFRA_FAIL written before die() | test-build-errors.sh |

Total paths: 43 → 46. Fixed-core coverage: 37/46 = 80.4% (>80% target met).

---

## Commits

| Commit | What |
|---|---|
| `docs(quality-pass)` | This design doc |
| `fix(build)` | INFRA_FAIL before validation; test-build-errors.sh; dev-test 43→46 |
| `feat(programs)` | V/Q verbosity; monitor elapsed time; bash 5.1 declare -A pitfall |
| `fix(preflight)` | Standard info()/warn() format instead of bare printf |
| `fix(mklog)` | Use info() so all orchestration lines carry INFO prefix |
| `fix(programs)` | Route build output through mklog.sh; suppress make noise |
| `fix(make)` | MAKEFLAGS += --no-print-directory eliminates make[N] noise |
