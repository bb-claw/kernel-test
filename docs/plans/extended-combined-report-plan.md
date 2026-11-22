# Extended combined report — Plan

Branch: `fix/extended-combined-report`
Start date: 2026-09-19

---

## Situation

`make extended` runs three phases in sequence: `perf-build → full → ns-full`. Each
phase invokes `lib/report.sh`, which writes `summary.txt` for only the configs it was
given. Because `ns-full` runs last it overwrites `summary.txt`, silently discarding the 5
plain configs from `full`. The Telegram notification script reads `summary.txt` verbatim,
so the 5 plain configs (kunitconfig, tinyconfig, defconfig, randdefconfig, rand500config)
are invisible in every `extended` notification.

---

## Problems to Solve

1. **Summary overwrite** — `ns-full`'s `report.sh` call overwrites `full`'s `summary.txt`,
   so the 5 plain configs disappear from the report and notification.
2. **OVERALL misses phase-1 failures** — A failure in `full` (e.g. rand500config timeout)
   is not reflected in the combined OVERALL written by the `ns-full` pass.

---

## Goals

1. `make extended` produces a single `summary.txt` covering all 10 configs (5 full + 5 ns-full).
2. OVERALL=FAIL if any of the 10 configs failed in either phase.
3. Standalone `make full`, `make ns-full`, `make smoke` continue to produce correct
   single-phase summaries — no regressions.
4. `diff-prev.txt` covers all 10 configs automatically (it already scans vmstatus-*.txt files).
5. The Telegram notification script (`kernel-test-poll.sh`) requires no changes.

---

## Scope

Files/components changed:
- `lib/report.sh` — sentinel-based append mode (4 small changes)
- `tests/ci/test-combined-report.sh` — new Tier 2 CI test (functional mock)

No changes to: `Makefile`, `kernel-test-poll.sh` (outside this repo), any other lib script.

---

## Non-goals

- Changing the Telegram notification script or its polling behaviour.
- Merging HTML reports across phases (summary.html is rebuilt fully on the second pass).
- Two separate report dirs per extended run.
- Parallelising full and ns-full.

---

## Design decisions

### Sentinel file in BUILD_DIR

`report.sh` writes `$BUILD_DIR/.report-extended-phase` after completing its first pass.
The second pass reads it, and processes the first-pass configs before its own configs.

Content:
```
RUN_STAMP=2026-09-17T22:06:54Z
CONFIGS=kunitconfig tinyconfig defconfig randdefconfig rand500config
```

**Why sentinel over Makefile changes:** No Makefile changes needed; the detection is
fully inside `report.sh`. Standalone targets (`make full`, `make smoke`) are unaffected
because the sentinel they write is either never read (no second pass follows) or is
found stale (different RUN_STAMP) and discarded.

**Why RUN_STAMP as the stale-check key:** Both `full` and `ns-full` inherit the same
`RUN_STAMP` from the top-level Makefile (it is computed once at parse time and exported).
A sentinel from a previous run will have a different RUN_STAMP and is silently discarded.

**Where sentinel lives:** `BUILD_DIR` (default `build/`) — both phases share the same
`BUILD_DIR`. The sentinel is removed on the second pass before report.sh returns.

### Combined OVERALL in the loop

`OVERALL` is computed inside the config×arch loop. By extending the loop to cover
`EXTRA_CONFIGS` (phase-1 configs) before `CONFIGS` (phase-2), `OVERALL` naturally
reflects all 10 builds. No separate re-scan step is needed.

### Artifacts and vmstatus files

Phase-1 artifacts (vmstatus-*.txt, build-*.log, etc.) were already copied into `RUN_DIR`
by the first pass. The second pass iterates them again (via EXTRA_CONFIGS) and re-copies
the same files — idempotent and harmless. `diff.sh` already scans all `vmstatus-*.txt`
in the report dir, so the diff automatically covers all 10 configs on the second pass.

### Duration

`ORIG_RUN_STAMP` is set from the sentinel's `RUN_STAMP` on the second pass (which equals
`RUN_STAMP` since both passes share the same value). Duration is computed as wall-clock
from `ORIG_RUN_STAMP` to `REPORT_GEN_EPOCH` — covering the full extended run on both passes.

---

## Testing strategy

- **CI functional mock** — `tests/ci/test-combined-report.sh`: simulates two `report.sh`
  invocations with the same `RUN_STAMP`; verifies combined output, OVERALL propagation,
  sentinel lifecycle, and stale-sentinel discard.
- **Standalone regression** — same test verifies that a standalone `make full`-equivalent
  (one call, no matching second pass) produces only its own rows.
- **No kernel/QEMU required** — all tests use mock `build.status` and `vm.status` files.

---

## Testing commands

```sh
# Always run before pushing any branch
make dev-test
# Expected: exit 0, ≥50% decision paths covered within time budget

# 1. Run the new CI test in isolation
bash tests/ci/test-combined-report.sh
# Expected: all tests pass, exit 0

# 2. Run the full Tier 2 suite
make ci-test
# Expected: exit 0

# 3. Lint check
make lint
# Expected: exit 0
```
