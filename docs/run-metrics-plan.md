# Run Metrics & Live Monitor — Plan

Branch: `feat/run-metrics`
Status: **in progress**

---

## Problem

kernel-test runs are a black box while in progress. You can see make output scroll by but have
no visibility into: how many builds are concurrently active, how hard the CPU is working, whether
ccache is effective, or which combo is the bottleneck. Post-run, timing information is scattered
across individual `build.status` and `vm.status` files with no aggregated view.

---

## Goals

1. Live dashboard (`make monitor`) showing active builds/tests, cc1 parallelism, and load in real time.
2. Per-run `metrics.txt` aggregating all timing and cache KPIs into one file.
3. "Build Performance" section appended to `summary.txt` / `summary.html` after each run.
4. CI test asserting the metrics file is well-formed.

---

## KPIs and Rationale

| KPI | Where captured | Why it matters |
|---|---|---|
| **Build wall time** | `metrics.txt` | Primary measure of build throughput. Lower = parallelism working. |
| **Test wall time** | `metrics.txt` | Primary measure of test throughput. |
| **Per-combo build time** | `metrics.txt` | Identifies bottleneck (config, arch) pairs — e.g. i386 allmodconfig. |
| **Per-combo test time** | `metrics.txt` | TCG arches expected 3–5× slower than KVM; outliers flag QEMU issues. |
| **ccache hit rate** | `metrics.txt` | Target >95% on repeat runs. Low rate = slower builds, cache misconfigured. |
| **Concurrent builds peak** | `make monitor` | Should equal min(PARALLEL_BUILDS, remaining). Drops = scheduling gap. |
| **cc1 peak count** | `make monitor` + `metrics.txt` if monitor ran | Actual compile parallelism. Low vs nproc = token starvation or all-cache. |
| **Kbuild make depth** | `make monitor` | Token consumers above cc1. High count with low cc1 = starvation. |
| **Active VMs** | `make monitor` | How many QEMU instances are running. Should stay ≤ PARALLEL_VMS. |
| **System load** | `make monitor` | 1-min avg from /proc/loadavg. Context for whether machine is CPU-bound. |

**Interpretation guide:**

- `build wall time` ≈ slowest combo time / PARALLEL_BUILDS — if much worse, scheduling gaps exist.
- `ccache hit rate` < 90% on a warm run: check CCACHE_MAX_SIZE (25G default), kernel tree changes.
- `cc1 peak` near zero on a warm cache run is normal; near nproc is the cold-build ideal.
- `test wall time` dominated by TCG arches (arm64, riscv): parallelism limited by PARALLEL_VMS.

---

## Architecture

### Sentinel files (zero-cost state tracking)

`lib/build.sh` touches `$OUT_DIR/.build-active` on start and removes it in the EXIT trap.
`lib/vm.sh` does the same with `$OUT_DIR/.vm-active`.

These files let the monitor and metrics collector determine in-progress state without polling
process tables or reading incomplete status files.

```
build/
  defconfig-x86_64/
    .build-active        ← exists only while build.sh is running
    build.status         ← written at end (DURATION already present at start via INFRA_FAIL sentinel)
    .vm-active           ← exists only while vm.sh is running
    vm.status            ← written at end
```

### lib/monitor.sh

Live dashboard, called by `make monitor` in a separate terminal. Runs a 2-second refresh loop:

1. Count `.build-active` files → active builds + elapsed time (mtime of sentinel = start time).
2. Count `.vm-active` files → active VMs.
3. `ps ax` → cc1 count, kbuild-make count, cc1 CPU%.
4. `/proc/loadavg` → 1-min load.
5. Read `build/*/build.status` with non-INFRA_FAIL STATUS → completed builds.
6. Optionally append sample to `$BUILD_DIR/.monitor-samples` for post-run peak computation.
7. Read most recent `metrics.txt` from `$REPORT_DIR` → delta section vs last run.

Sample output:
```
  KERNEL-TEST MONITOR                                      13:30:15
  ─────────────────────────────────────────────────────────────────

  BUILDS (3 active / 5 done)   cc1: 7  kbuild: 16   CPU: 305%  load: 6.1
    defconfig/x86_64     2m14s
    defconfig/i386       2m08s
    tinyconfig/arm64     1m45s

  TESTS  (2 active / 2 done)
    defconfig/x86_64     0m35s
    tinyconfig/x86_64    0m18s

  ─────────────────────────────────────────────────────────────────
  vs last run (mainline-7.2-2026-09-26...):
    build wall: 5m24s → (in progress)   ccache: 96%
  ─────────────────────────────────────────────────────────────────
```

### lib/metrics.sh

Called by `lib/report.sh` after all builds and tests are complete. Receives:
- `$RUN_DIR` — the report directory to write into
- `$BUILD_DIR/.ccache-stats-before` — ccache snapshot taken at the start of `make build`

Reads all `build.status` and `vm.status` files, computes wall times via earliest-start /
latest-end across all combos. Reads current ccache stats and subtracts the before-snapshot
to get per-run delta. Optionally reads `.monitor-samples` for peak job counts.

Writes `$RUN_DIR/metrics.txt` and appends a "Build Performance" section to `summary.txt`
and a corresponding HTML section to `summary.html`.

### ccache stats snapshot

`Makefile` writes `ccache -s > $(BUILD_DIR)/.ccache-stats-before` at the start of `make build`
(before any build.sh invocation). This captures the cumulative ccache counter values so
`lib/metrics.sh` can compute the per-run delta by subtracting.

---

## metrics.txt format

Plain-text key=value, one per line. Comments with `#`. Parseable with `grep/cut`.

```
# kernel-test run metrics — generated by lib/metrics.sh
RUN_STAMP=2026-09-27_13-28-51

# Build phase
BUILD_COMBOS=8
BUILD_WALL_TIME=324

# Per-combo build times (seconds)
BUILD_TIME_defconfig_arm64=98
BUILD_TIME_defconfig_i386=51
BUILD_TIME_defconfig_x86_64=45
BUILD_TIME_tinyconfig_arm64=31
...

# ccache stats (delta for this run)
CCACHE_HITS=1234
CCACHE_MISSES=56
CCACHE_HIT_RATE_PCT=95

# Test phase
TEST_COMBOS=8
TEST_WALL_TIME=412

# Per-combo test times (seconds)
TEST_TIME_defconfig_arm64=185
TEST_TIME_defconfig_x86_64=95
...

# Peak job counts (populated when make monitor ran during the build)
PEAK_BUILD_JOBS=4
PEAK_CC1_JOBS=12
PEAK_KBUILD_MAKES=18
PEAK_LOAD=6.10
PEAK_CPU_PCT=386
```

---

## Implementation Commits

| # | Files | What |
|---|---|---|
| 1 | `docs/run-metrics-plan.md` | This design doc |
| 2 | `lib/build.sh`, `lib/vm.sh` | `.build-active` / `.vm-active` sentinels |
| 3 | `lib/metrics.sh` | Metrics aggregation script |
| 4 | `lib/monitor.sh` | Live monitoring dashboard |
| 5 | `lib/report.sh`, `Makefile` | Integration: ccache snapshot, metrics call, report section |
| 6 | `tests/ci/test-metrics.sh` | CI format assertions |
| 7 | memory | `project.md`, `workflows.md` updates |

---

## Design Decisions

### Why sentinel files instead of polling build.status

`build.status` is written atomically at the END of a build. An in-progress build has only the
`INFRA_FAIL` sentinel line. Polling for the absence of a real STATUS would be fragile. The
`.build-active` file exists for exactly the duration of the build process, making it a reliable
in/out indicator.

### Why ccache delta not total

Cumulative ccache counters grow across all runs. Reporting the delta (this-run contribution)
makes the metric meaningful per-run and comparable across runs regardless of total cache age.

### Why metrics are optional for peak job counts

Peak CPU/job counts require a background sampler. If `make monitor` is not running, these
fields are absent from metrics.txt. The core metrics (timing, ccache) are always present.
This avoids requiring a background daemon in the main pipeline.

### Why wall time not sum of durations

`sum(DURATION)` grows linearly with combo count regardless of parallelism. Wall time shrinks
as parallelism improves, making it the correct metric for evaluating scheduling effectiveness.
It directly answers: "how long did I wait?"
