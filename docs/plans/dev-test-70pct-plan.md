# dev-test >70% coverage floor — Plan

Branch: `feat/dev-test-70pct`
Start date: 2026-08-18

---

## Situation

`make dev-test` was a ≤6-minute branch gate with a ≥50% coverage target (informational only — the
script passed regardless of actual path count). The fixed core guaranteed only ~44% of the 36
functional decision paths, leaving the remaining coverage to a random pool draw that could miss
the target under time pressure. There was no enforcement: a run covering 40% still exited 0.

---

## Problems to Solve

1. **Coverage floor not enforced** — dev-test passed with any coverage percentage; the "≥50%" in the
   header was aspirational, not a hard gate.
2. **10 fast CI tests in random pool** — weight-1 entries (E1–F4, each <5 s) were in the random
   pool and could be skipped by budget or random ordering, creating variance in which paths run.
3. **test-syscall-tests.sh not in dev-test** — the new CI test added for 490_bpf / 500_sysvipc
   was absent from both fixed core and the random pool.

---

## Goals

1. Fixed core (C1–C9) guarantees ≥72% of 36 paths (≥26/36 without /proc/config.gz, ≥27/36 with it).
2. dev-test exits non-zero when coverage ≤ 70% or any step fails.
3. All 10 weight-1 CI tests run deterministically every time.
4. `test-syscall-tests.sh` included in C3 key-CI step.

---

## Scope

Files changed:

- `scripts/dev-test.sh` — add C9 fixed-core loop, move E1–F4 out of pool, add threshold check,
  add `test-syscall-tests.sh` to C3, reduce TARGET_RANDOM 9→4, update header comment
- `tests/ci/coverage-map.md` — update E1–F4 "Covering scenario" to fixed core via C9; add
  coverage floor note to header
- `CLAUDE.md` — update dev-test description (≥50% → >70%)
- `memory/code-quality.md` — update review checklist (≥50% → >70%)
- `memory/workflows.md` — update dev-test description

---

## Design

### Fixed-core guarantee

| Step | Paths covered |
|------|--------------|
| C1 lint | — |
| C2 programs | C6, C7 |
| C3 key CI (5 suites) | C1, C2, C3, C4, C5 |
| C4 tinyconfig/x86_64 | A1, A2, A3, A6, A8, B1, B2 |
| C5 defconfig/x86_64 | (subset already covered) |
| C6 localconfig/x86_64 | B5 (conditional on /proc/config.gz) |
| C7 tinyconfig/i386 | D3 |
| C8 defconfig/i386 | D7 |
| C9 E1–F4 (10 CI tests) | E1, E2, E3, E4, E5, E6, F1, F2, F3, F4 |

Guaranteed total: 27/36 = 75% (26/36 = 72% without localconfig). Both exceed the 70% floor.

### Threshold enforcement

```bash
if [[ $fail_count -eq 0 ]] && [[ $pct -gt 70 ]]; then
    exit 0
else
    # differentiated message: failure vs coverage shortfall
    exit 1
fi
```

### Random pool (remaining VM combos)

After removing E1–F4, pool contains: A4_A5_A7, B3, B4, B6, D1(arm64), D2(riscv), D4–D6(board).
TARGET_RANDOM reduced 9→4; budget remaining (~255 s) comfortably accommodates a few VM boots.

---

## Verification

- `make dev-test` → 32/36 paths (88%), 195 s
- Fixed core alone covers 27 paths before random pool draw
- Threshold check: would fail at 70% or below
