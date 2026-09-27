# Quality Pass — Plan

Branch: `feat/quality-pass`
Status: **in progress**

---

## Goals

1. Raise `make dev-test` fixed-core path coverage from 74% (32/43) to >80% (≥35/43).
2. Fix `build.sh` error-path correctness: early `die()` calls that fire before `STATUS=INFRA_FAIL` is written can leave stale `STATUS=PASS` from a previous run.
3. New CI test suite covering build.sh failure modes (A4, A5) and INFRA_FAIL lifecycle.
4. Normalize programs/ns build output at V=0 to suppress per-binary compiler command lines.

Bugs found during audit: fixed in-branch per user preference.

---

## Audit Findings

### 1 — build.sh early `die()` before INFRA_FAIL (bug)

`OUT_DIR`, `mkdir -p`, and `STATUS=INFRA_FAIL` are written at lines 43–60.
Three validation `die()` calls fire at lines 30–41, **before** the build dir or sentinel exist:

| Line | Check | Risk |
|---|---|---|
| 30 | Unsupported arch | If prior run left `STATUS=PASS`, stale PASS survives |
| 36 | Kernel tree missing | Same — tree deleted/remounted between runs |
| 41 | Host compiler missing | Same — compiler uninstalled |

**Fix:** Move `OUT_DIR` assignment, `mkdir -p`, and `STATUS=INFRA_FAIL` write to before the validation block (lines 43→17, before the arch case).

### 2 — build.sh failure modes not in fixed CI core (coverage gap)

| Path | Description | Current coverage |
|---|---|---|
| A4 | Build FAIL → STATUS=FAIL written, no boot | Random pool only (weight 2) |
| A5 | Build TIMEOUT (exit 124) → STATUS=TIMEOUT | Random pool only (weight 2) |

Neither path has a CI fixture test. If the random pool skips these (budget exceeded), the gates are undetected.

**Fix:** New `tests/ci/test-build-errors.sh` with fixture-based tests covering A4, A5, INFRA_FAIL lifecycle, and early die() paths. Moves both to fixed core → 34/43 = 79%; combined with existing fixed paths → 35/43 = 81%.

### 3 — Programs/ns build output inconsistency (formatting)

During `make programs`, `tests/common.mk` and `tests/ns/Makefile` print:
```
[ns] riscv  ns-time
riscv64-linux-gnu-gcc -std=c17 -O2 ... -o bin/riscv/ns-time ns-time.c
```
The full compiler command is always visible — unlike kernel builds at V=0 which are silent per combo. This is the largest visible formatting inconsistency during `make all`.

**Fix:** Add `$(Q)` prefix to compiler invocations in `tests/common.mk` and `tests/ns/Makefile` so V=0 (default) suppresses command lines; the `[tag] arch  binary` summary line is kept.

### 4 — Makefile hw-deploy/install bare printf (minor)

`hw-deploy` and `install` targets use `printf '[hw-deploy] ...'` / `printf '[install] ...'` directly, bypassing `lib/mklog.sh`'s timestamp format. Only visible during hw targets, not `make all`.

**Fix:** Route through `lib/mklog.sh` for consistency.

---

## New CI Paths (coverage-map additions)

| ID | Description | Covering scenario |
|---|---|---|
| I1 | build.sh early die(): unsupported arch exits non-zero, no STATUS written | test-build-errors.sh fixture |
| I2 | build.sh early die(): missing kernel tree writes INFRA_FAIL if OUT_DIR pre-exists | test-build-errors.sh fixture |
| I3 | INFRA_FAIL lifecycle: written at start, overwritten STATUS=FAIL on config failure | test-build-errors.sh fixture |
| I4 | STATUS=TIMEOUT written when build exits 124 (BUILD_TIMEOUT) | test-build-errors.sh fixture |

I1–I4 move into fixed core via C9 (ci-test); coverage 35+/43 = 81%.

---

## Implementation Commits

| # | Files | What |
|---|---|---|
| 1 | `docs/quality-pass-plan.md` | This design doc |
| 2 | `lib/build.sh` | Move mkdir+INFRA_FAIL before early validation die()s |
| 3 | `tests/ci/test-build-errors.sh` | New: A4, A5, INFRA_FAIL lifecycle, early die() paths |
| 4 | `tests/common.mk`, `tests/ns/Makefile` | Add `$(Q)` to compiler lines; V=0 suppresses commands |
| 5 | `Makefile` | Route hw-deploy/install prints through mklog.sh |
| 6 | `tests/ci/coverage-map.md` | Add I1–I4 to fixed core; update count |
| 7 | memory | `project.md`, `code-quality.md` updates |
