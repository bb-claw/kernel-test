# extended: continue past partial failures + perf-build in report — Plan

Branch: `fix/extended-partial-failure-and-perf-report`
Start date: 2026-09-14

---

## Situation

`make extended` is the staging automation target: full (5 configs) + ns-full (5 ns-variant
configs) + perf-build. A v7.2.6 stable run exposed two bugs when rand500config had two boot
failures (x86_64 timeout, arm64 kernel panic): Make aborted `extended` after `full` exited
non-zero, so `ns-full` and `perf-build` never ran; and the summary contained no trace of the
perf build even when it does run.

---

## Problems to Solve

1. **extended aborts on partial test failures** — `$(MAKE) full` exits non-zero when any
   config/arch boots but has test failures. Make's default behaviour aborts `extended` at that
   point, silently skipping `ns-full` and `perf-build`. A boot failure in one config is not a
   reason to skip the independent namespace suite or the host-side perf build.

2. **perf-build result invisible in the report** — `perf-build` writes only to
   `build/perf/build.log`. `lib/report.sh` never reads that file, so `summary.txt` and the
   report directory contain no trace of whether perf-build ran, passed, or failed.

---

## Goals

1. `make extended` runs all three phases (full, ns-full, perf-build) regardless of per-phase
   exit codes, and exits non-zero if any phase failed.
2. `make perf-build` writes `$BUILD_DIR/perf/build.status` (STATUS=PASS/FAIL/SKIP).
3. `lib/report.sh` appends `Perf build: PASS/FAIL/skipped` to `summary.txt` when the status
   file exists.
4. All three behaviours covered by `tests/ci/test-extended-perf-report.sh`.

---

## Scope

Files changed:
- `Makefile` — `extended` recipe (rc accumulator); `perf-build` recipe (use `$(BUILD_DIR)`,
  write status file)
- `lib/report.sh` — read `$BUILD_DIR/perf/build.status`, append line to summary.txt
- `tests/ci/test-extended-perf-report.sh` — new CI test (Tier 2, no kernel/QEMU)

No changes to: `lib/vm.sh`, `lib/build.sh`, `lib/initramfs.sh`, any VM test scripts.

---

## Non-goals

- Parallelising full/ns-full/perf-build inside extended (serial order preserved).
- Surfacing perf-build result in summary.html or summary.mail.txt (txt is sufficient for now).
- Changing how `make full` or `make all` propagate their own exit codes.

---

## Design decisions

### rc accumulator pattern for extended

```makefile
extended:
	+@rc=0; \
	 $(MAKE) full       || rc=$$?; \
	 $(MAKE) ns-full    || rc=$$?; \
	 $(MAKE) perf-build || rc=$$?; \
	 exit $$rc
```

`rc` accumulates the first non-zero exit code seen; all three sub-makes run regardless.
The `+` prefix keeps jobserver tokens flowing; `@` suppresses the recipe echo.
Alternative (`-$(MAKE) full; -$(MAKE) ns-full`) always exits 0 — rejected: staging
automation needs to detect any phase failure.

### perf-build status file location

`$BUILD_DIR/perf/build.status` — same directory as `build.log`, consistent with the
`build/<config>-<arch>/build.status` pattern used for kernel builds. `BUILD_DIR` is already
exported and overridable on the Make command line, making the path testable in CI without
touching real build artifacts. Content: `STATUS=PASS`, `STATUS=FAIL`, or `STATUS=SKIP`.

### report.sh reads build.status, not build.log

`build.log` is large and unstructured. A one-line `build.status` file is the same pattern
used for kernel builds and is trivially parseable with `grep + cut`. The status file is
written by `perf-build` and read by `report.sh` — no direct coupling between the two targets.

---

## Testing strategy

- **Bug 1 (extended recipe)** — static grep: verify `|| rc=` appears in the extended recipe;
  functional test: invoke `make extended` with a mock `full` that exits 1 and verify
  `ns-full` still runs (checked via an output file written by the mock).
- **Bug 2 (status file)** — invoke `make perf-build NO_PERF_BUILD=1 BUILD_DIR=<tmp>` and
  assert `STATUS=SKIP` in the status file; run `lib/report.sh` with a pre-written PASS/FAIL
  status file and assert the summary.txt contains the `Perf build:` line.
- **Backward compat** — run `lib/report.sh` without any status file; assert no `Perf build:`
  line appears (existing test suites unaffected).

---

## Testing commands

```sh
# Always run before pushing
make dev-test
# Expected: exit 0, ≥70% decision paths

# 1. CI test suite
make ci-test
# Expected: test-extended-perf-report.sh passes all assertions

# 2. perf-build skip writes status file
make perf-build NO_PERF_BUILD=1
cat build/perf/build.status
# Expected: STATUS=SKIP

# 3. Structural check: extended recipe contains accumulator pattern
grep -A5 '^extended:' Makefile
# Expected: lines with || rc= for each sub-make

# 4. Lint
make lint
# Expected: exit 0
```
