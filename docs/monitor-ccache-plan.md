# Monitor — ccache + ETA + Throttle Plan

Branch: `feat/monitor-ccache`
Status: **in progress**

---

## Goals

1. Replace raw `ccache --show-stats` dump at the bottom of `make monitor` with a
   structured **CCACHE section** (this-run %, all-time %, size, direct/preprocessed
   split, errors, cleanups) placed after TESTS and before the delta block.
2. Add **ETA** to the header line (`run: Xm Ys → ETA ~Xm Ys`) when a run is active.
3. Add a **CPU throttle warning** line after the BUILDS header when the average CPU
   frequency drops below 80% of nominal; include peak thermal zone temp.
4. Adapt **separator lines** to terminal width via `tput cols` (min 60, max 100).
5. Consolidate the two separate ccache calls (live delta + raw dump) into one
   `ccache --show-stats` call per tick.

---

## Design Decisions

| Decision | Rationale |
|---|---|
| CCACHE section after TESTS | BUILDS/TESTS at top where you look first; ccache is secondary context |
| One `--show-stats` call per tick | Compute both delta and all-time from the same output; negligible overhead (<5 ms) |
| ETA in header line | Compact; extends existing `run: Xm Ys` naturally |
| ETA from build phase while builds active; test phase while tests active | Best available signal at each phase |
| Throttle warning only (silent when ok) | No noise at full speed; visible when the thermal profile matters |
| `tput cols` min 60 / max 100 | Works on narrow and wide terminals; 100-char cap prevents runaway wide output |
| Throttle threshold 80% of max | Meaningful drop (20%+ below nominal) without false positives from brief boost variation |

---

## New CI Paths (coverage-map additions)

| ID | Description | Covering scenario |
|---|---|---|
| M1 | monitor --once exits 0 with no active run (absent build dir) | test-monitor.sh |
| M2 | monitor --once output contains BUILDS and TESTS section headers | test-monitor.sh |

Total paths: 46 → 48. Fixed-core coverage: 39/48 = 81.3% (>80% target maintained).

---

## Commits

| Commit | What |
|---|---|
| `docs(monitor-ccache)` | This design doc |
| `feat(monitor)` | ccache section, ETA, throttle warning, adaptive separator width |
