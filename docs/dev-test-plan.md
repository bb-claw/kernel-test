# dev-test — Branch Verification Tooling Plan

Branch: `feat/dev-test`
Start date: 2026-08-16
Status: IN PROGRESS

---

## Situation

`make lint` (Tier 1) and `make ci-test` (Tier 2) verify code quality and harness
self-tests, but neither boots a kernel, exercises the full VM pipeline, or checks
C program compilation. A developer can push a broken branch without realising it
until a full `make all` run completes (20+ minutes).

`make dev-test` fills the gap: a ≤5-minute branch verification gate that covers 50%
of observable decision paths through a fixed core (always-run) + random draw
(different paths each run, reproducible via seed).

---

## Goals

1. Complete in ≤ 5 minutes on the laptop; warn (not abort) when exceeded.
2. Cover **50% of all identified decision paths** every run.
3. Fixed core covers the **top 25%** (most important) deterministically.
4. Random selection covers the **next 25%** from the remaining pool; seed printed
   and replayable with `make dev-test SEED=N`.
5. Single entry point: `make dev-test`.
6. Detect environment (laptop / Hetzner / hardware board); skip unavailable paths
   with an explicit `skip:` notice — never fail due to environment.
7. Optional pre-push hook via `make hook-dev-test` (per-machine opt-in).

---

## Decision Path Taxonomy

35 functional paths identified across 6 groups. Each has a coverage-map entry in
`tests/ci/coverage-map.md`.

### Group A — Core VM pipeline (8 paths)

| ID  | Path |
|-----|------|
| A1  | KVM available → `qemu -enable-kvm` (x86 fast boot) |
| A2  | KVM absent → TCG fallback (arm64/riscv always; x86 fallback) |
| A3  | Build PASS → initramfs built → VM boots → tests run |
| A4  | Build FAIL → `vm.status` shows FAIL, no boot attempted |
| A5  | Build TIMEOUT (exit 124) → `vm.status` shows TIMEOUT |
| A6  | BOOT=PASS → test scripts execute sequentially |
| A7  | BOOT=FAIL → TEST_DONE absent, vm.status BOOT=FAIL |
| A8  | `NO_BUILD=1` → kernel build skipped, initramfs rebuilt from existing bzImage |

### Group B — Config fragment mechanism (6 paths)

| ID  | Path |
|-----|------|
| B1  | Standard config (defconfig/kunit) → arch default + fragment + olddefconfig |
| B2  | tinyconfig base + fragment → minimal bootable kernel |
| B3  | rand500config → tinyconfig + 500 sampled random =y lines + bootability pin |
| B4  | randdefconfig → defconfig + 300 randomly disabled options + heavy-subsystem off |
| B5  | localconfig → `/proc/config.gz` sourced + olddefconfig + fragment |
| B6  | NS-variant config → base config merged with `configs/namespaces.config` |

### Group C — CI self-test and C program quality (7 paths)

| ID  | Path |
|-----|------|
| C1  | VM serial parser: `TESTS_PASS` / `TESTS_FAIL` from `< TEST PASS:` anchors |
| C2  | KUnit KTAP: `ok N` / `not ok N` lines counted from serial output |
| C3  | Report HTML generation (all config × arch → summary.html) |
| C4  | Diff: `PASS→FAIL` = regression, `FAIL→PASS` = fix, cross-run comparison |
| C5  | Snapshot: 27-field validation, ISSUES count, 20-bit taint decode |
| C6  | C programs (snapshot/syscall-tests/arena-test/perf-event): musl-gcc 4-arch build |
| C7  | C programs: musl-clang quality gate (x86_64, `-Weverything -Werror`) |

### Group D — Cross-arch and hardware (6 paths)

| ID  | Path |
|-----|------|
| D1  | arm64 TCG boot (cortex-a57, 1 G RAM, 2× TIMEOUT) |
| D2  | riscv TCG boot (requires `qemu-system-riscv64 ≥ 8.x`, FPU fragment) |
| D3  | i386 KVM/TCG boot (toybox-i686, 32-bit off\_t boundary syscalls) |
| D4  | Board: U-Boot SPL Phase 1 anchor + Phase 2 TEST_DONE anchor |
| D5  | Board: TFTP/PXE boot, kernel + DTB transfer |
| D6  | hw-bootstrap: networkd DHCPServer + atftpd TFTP + udev relay rule |

### Group E — Developer workflow tools (6 paths)

| ID  | Path |
|-----|------|
| E1  | `verify-patch` single mode: build one file/dir across arches + compilers |
| E2  | `verify-patch` before/after (BASE=): git worktree compare, verdict FIXED/UNCHANGED |
| E3  | `config-bisect`: 8-cycle binary search on candidate options, PINNED\_OPTS multi-pass |
| E4  | `kconfig-check`: subsystem dependency sweep, GATE\_CFGS, DRY\_RUN |
| E5  | `dmesg` host analysis: rcu/lockup/oom pattern extraction from running kernel |
| E6  | Warning analysis: per-combo counts, NEW/FIXED vs prev run, cross-arch divergence |

### Group F — Fetch strategies (4 paths)

| ID  | Path |
|-----|------|
| F1  | Mainline rc fetch: `git ls-remote --depth=1` for latest `v*-rc*` tag |
| F2  | Stable release fetch: `STABLE_RELEASE=X.Y` selects latest `vX.Y.*` tag |
| F3  | Stable-rc branch fetch: branch reset to `FETCH_HEAD` |
| F4  | linux-next: `make fetch-next` (separate clone, no rc tags) |

**Total: 35 paths.**

---

## Coverage Model

```
Fixed core  (25% = ~9 paths)  — always run, deterministic
Random pool (25% = ~9 paths)  — drawn from remaining 26 paths using SEED
─────────────────────────────────────────────────────────────
Total coverage: ≥ 50% every run
```

### Fixed core scenarios → paths covered

| Scenario | Paths covered |
|---|---|
| `make lint` | meta: shellcheck, inventory, context sizes |
| `make -C tests/programs all` (incremental) | C6, C7 |
| `tests/ci/test-vm-parser.sh` + `test-report.sh` + `test-snapshot.sh` + `test-diff.sh` | C1, C2, C3, C4, C5 |
| `tinyconfig/x86_64` VM smoke (`NO_BUILD=1`) | A1 or A2, A3, A6, A8, B1, B2 |
| `defconfig/x86_64` VM smoke (`NO_BUILD=1`) | A1 or A2, A3, A6, B1 |
| `localconfig/x86_64` VM smoke (`NO_BUILD=1`, skip if no `/proc/config.gz`) | B5 |

Fixed core covers deterministically: **A1–A3, A6, A8, B1, B2, B5, C1–C7**
= 14 of 35 paths = **40%** (above the 25% minimum; random fills the remaining 10%+).

### Random pool

Remaining 21 paths: **A4, A5, A7, B3, B4, B6, D1–D6, E1–E6, F1–F4**.

Each run draws paths weighted by estimated test duration until 25% (≈9) additional
paths are covered or the remaining time budget (5 min − fixed-core elapsed) is
exhausted. Hardware-only paths (D4–D6) are excluded from the draw when hardware is
absent; fetch paths (F1–F4) are exercised via CI fixture replays rather than live
network calls.

Path weights (lower = preferred for time budget):

| Weight | Paths | Estimated duration |
|--------|-------|--------------------|
| 1 | E1–E6, F1–F4 | < 30 s each (CI fixtures or dry-run) |
| 2 | A4, A5, A7, B3, B4, B6 | 20–60 s each (VM config combos) |
| 3 | D1–D3 | 60–120 s each (TCG VMs) |
| skip | D4–D6 | hardware absent on most machines |

---

## Environment Detection

Performed once at startup; results cached in shell variables for all scenarios.

```
HAS_KVM      → [ -r /dev/kvm ]
HAS_LOCAL    → [ -r /proc/config.gz ]
HAS_BOARD    → [ -e /dev/ttyUSB0 ] || [ -L "${HW_RELAY:-/dev/vf2-relay}" ]
HAS_RISCV_CC → command -v riscv64-linux-gnu-gcc
HAS_ARM64_CC → command -v aarch64-linux-gnu-gcc
IS_HETZNER   → [ ! HAS_KVM ] && [ ! HAS_LOCAL ]
```

Environment banner printed at the top of every run:

```
[dev-test] env: laptop KVM=yes local=yes board=no riscv-cc=yes arm64-cc=yes
```

---

## Timing Budget

Total soft budget: **300 seconds**.

Approximate allocation:

| Stage | Expected duration |
|---|---|
| `make lint` | 5 s |
| C programs build (incremental) | 15 s |
| 4 key CI tests | 30 s |
| tinyconfig/x86_64 smoke | 20 s |
| defconfig/x86_64 smoke | 30 s |
| localconfig/x86_64 smoke (or skip) | 30 s |
| Random scenarios | 60–120 s |
| **Total** | **190–250 s** |

If elapsed > 300 s at the start of a new scenario, dev-test prints a soft warning
and skips remaining scenarios (it does not kill in-flight processes).

---

## Output Format

```
[dev-test] seed=1234567  env: laptop KVM=yes local=yes board=no
──────────────────────────────────────────────────────────────────
  PASS  lint                                          5s
  PASS  C programs build (4 arches × 4 programs)    14s
  PASS  ci-tests: vm-parser report snapshot diff     31s
  PASS  VM smoke: tinyconfig/x86_64  50/50           19s
  PASS  VM smoke: defconfig/x86_64   50/50           28s
  skip  VM smoke: localconfig/x86_64  (/proc/config.gz absent)
── random (seed=1234567, 9 of 21 paths) ──────────────────────────
  PASS  ci-test: test-fetch.sh                        8s
  PASS  VM smoke: kunitconfig/x86_64  50/50 kunit:259/259  61s
  PASS  ci-test: test-warnings.sh                    12s
  skip  VM smoke: defconfig/arm64  (TCG — 120s budget exceeded)
  PASS  ci-test: test-diff.sh                         9s
  ...
──────────────────────────────────────────────────────────────────
  PASS  dev-test complete  paths=23/35 (66%)  time=187s
```

On failure:

```
  FAIL  VM smoke: tinyconfig/x86_64  49/50  [480_snapshot]
──────────────────────────────────────────────────────────────────
  FAIL  dev-test FAILED  paths=18/35 (51%)  time=142s
        re-run: make dev-test SEED=1234567
```

Exit 0 on all PASS/skip; exit 1 on any FAIL.

---

## File Structure

```
scripts/dev-test.sh          main script; invoked by make dev-test
tests/ci/coverage-map.md     35-path registry: ID, description, covering scenario(s)
.githooks/pre-push           existing hook; extended by make hook-dev-test
```

`scripts/dev-test.sh` sections:
1. Environment detection
2. Seed initialisation (`SEED` env var or `$RANDOM`)
3. Fixed-core runner (sequential, abort on FAIL)
4. Random-pool selector (weighted draw from remaining paths)
5. Summary table + exit code

---

## Makefile Targets

```makefile
dev-test:
	@scripts/dev-test.sh

dev-test SEED=1234567:
	@SEED=1234567 scripts/dev-test.sh

hook-dev-test:
	# Installs / removes dev-test from .githooks/pre-push (toggle)
```

`make hook-dev-test` appends/removes a `make dev-test || exit 1` call inside the
existing pre-push hook function. Toggle: running it again removes what it added.

---

## Coverage Map Format (`tests/ci/coverage-map.md`)

Each row:

```
| ID | Description | Covering scenario | Group |
```

Example:

```
| A3 | Build PASS → initramfs built → VM boots | tinyconfig/x86_64 smoke | A-pipeline |
| B2 | tinyconfig + fragment → minimal kernel   | tinyconfig/x86_64 smoke | B-config   |
| D1 | arm64 TCG boot                           | random pool (weight 3)  | D-crossarch|
```

Updated via PR whenever a new decision path is introduced (new lib script branch,
new config profile, new CI test). The pre-push hook's design-doc check already
enforces that `feat/*` branches have a plan doc; coverage-map.md is maintained
alongside it.

---

## Reproducibility

```sh
make dev-test              # random seed each run; seed printed
make dev-test SEED=1234567 # exact same path selection as the original run
```

Seed governs only random-pool selection. Fixed core always runs identically.

---

## Testing Commands

```sh
# After implementation:
make dev-test                          # full run
make dev-test SEED=42                  # replay specific seed
make hook-dev-test                     # install in pre-push
make hook-dev-test                     # run again to uninstall
time make dev-test                     # verify ≤ 5 min budget
```

---

## Non-goals

- Does not replace `make all` for final release verification.
- Does not replace `make ci-test` (Tier 2); dev-test runs a subset of it.
- Does not instrument bash for true per-line branch coverage (too slow).
- Does not run `make extended` (10 full config runs; ~30 min).
