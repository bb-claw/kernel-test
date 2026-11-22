# Common Serial Parser — Plan

Branch: `refactor/common-serial-parser`
Start date: 2026-08-06

---

## Situation

`lib/vm.sh` does two distinct things: (1) QEMU-specific mechanics — arch config, machine
flags, process launch — and (2) generic serial output processing — parsing the dmesg file,
determining boot status, writing `vm.status`, and logging the result. Phase 5
(`feat/board-serial`) needs `lib/board.sh` to do the same (2) without duplicating ~140
lines of parser logic. This refactor extracts (2) into shared helpers in `lib/common.sh`
before board.sh is written, so it is never duplicated.

---

## Problems to Solve

1. **Parser is locked inside vm.sh** — `lib/board.sh` cannot reuse it without copying it,
   creating two copies that will drift.
2. **vm.sh conflates boot mechanism with result processing** — hard to test the parser
   independently of QEMU.
3. **No CI coverage for the parser logic** — the only test is an end-to-end QEMU run;
   regressions in parse or status-writing logic surface only after a full boot.

---

## Goals

1. Four new functions in `lib/common.sh`: `parse_serial_output`, `determine_boot_status`,
   `write_run_status`, `log_run_result` — covering all result-processing logic from vm.sh.
2. `lib/vm.sh` reduced to: arch setup → QEMU launch → four function calls → CANARY
   post-check. No inline parsing remains.
3. No behaviour change — identical `vm.status` content and terminal output before and after.
4. New CI test `tests/ci/test-vm-parser.sh` with five fixture transcripts covering all
   parser paths: happy path, kernel panic, timeout (QEMU path), timeout (board path),
   KTAP block, CANARY marker.
5. `REPO_ROOT`-based source path standardised in `lib/vm.sh`.

---

## Scope

Files changed:
- `lib/common.sh` — add four functions (parse_serial_output, determine_boot_status,
  write_run_status, log_run_result)
- `lib/vm.sh` — remove inline parser; replace with function calls; standardise source
  path to `REPO_ROOT`-based
- `tests/ci/test-vm-parser.sh` — new CI test (new file)
- `tests/ci/fixtures/parser/` — five fixture transcript files (new directory)

No changes to: `lib/board.sh` (does not exist yet), `lib/build.sh`, `lib/initramfs.sh`,
`lib/report.sh`, any test scripts, Makefile.

---

## Non-goals

- No changes to the QEMU command line or arch configuration
- No behaviour change of any kind — identical output before and after
- No streaming/live-parse mode — file-based interface only (board.sh will tee to dmesg.txt)
- No board.sh stub — that is Phase 5

---

## Design Decisions

### Function signatures

```bash
# parse_serial_output <dmesg_file>
# Sets globals: BOOT_OK PANIC OOPS TEST_DONE
#               PASS_COUNT FAIL_COUNT TESTS_TOTAL FAILED_TESTS
#               KUNIT_PASS KUNIT_FAIL CANARY_EARLY
parse_serial_output() { local dmesg_file="$1"; ... }

# determine_boot_status <dmesg_file> <exit_code> <timeout_occurred>
# Reads globals set by parse_serial_output (BOOT_OK, PANIC, OOPS, TEST_DONE)
# Sets globals: BOOT_STATUS FAIL_REASON
# exit_code=124 OR timeout_occurred=1 → Timeout FAIL_REASON (two callers, two detection methods)
determine_boot_status() { local dmesg_file="$1" exit_code="$2" timeout_occurred="$3"; ... }

# write_run_status <status_file> <start_time> <duration>
# Reads globals: BOOT_STATUS TEST_DONE TESTS_TOTAL PASS_COUNT FAIL_COUNT
#                KUNIT_PASS KUNIT_FAIL FAIL_REASON FAILED_TESTS CANARY_EARLY
write_run_status() { local status_file="$1" start_time="$2" duration="$3"; ... }

# log_run_result <run_label>
# Reads globals: BOOT_STATUS PASS_COUNT TESTS_TOTAL KUNIT_PASS KUNIT_TOTAL
#                FAIL_COUNT KUNIT_FAIL FAIL_REASON FAILED_TESTS
# Returns: 0 on full PASS; 1 on PARTIAL (test failures) or FAIL (boot failure)
log_run_result() { local run_label="$1"; ... }
```

### vm.sh post-refactor call sequence

```bash
# ... arch setup (case "$ARCH") unchanged ...

VM_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VM_START_EPOCH=$(date -u +%s)
QEMU_EXIT=0
timeout "$VM_TIMEOUT" "$QEMU" \
    ... \
    -serial "file:$DMESG_FILE" \
    > /dev/null 2> "$QEMU_LOG" \
    || QEMU_EXIT=$?
VM_DURATION=$(( $(date -u +%s) - VM_START_EPOCH ))

parse_serial_output      "$DMESG_FILE"
determine_boot_status    "$DMESG_FILE" "$QEMU_EXIT" 0
write_run_status         "$STATUS_FILE" "$VM_START_TIME" "$VM_DURATION"
log_run_result           "$CONFIG / $ARCH" || exit 1

# CANARY post-check stays in vm.sh — QEMU/build-specific, board.sh never uses it
if [[ "${CANARY:-0}" == 1 && ... ]]; then ...
```

### board.sh call sequence (Phase 5 contract — not implemented here)

```bash
# board.sh detects timeout via read -t; no process exit code
TIMEOUT_OCCURRED=0
while IFS= read -r -t "$TIMEOUT" line <&3; do
    printf '%s\n' "$line" >> "$DMESG_FILE"
done || TIMEOUT_OCCURRED=1

parse_serial_output      "$DMESG_FILE"
determine_boot_status    "$DMESG_FILE" 0 "$TIMEOUT_OCCURRED"
write_run_status         "$STATUS_FILE" "$START_TIME" "$DURATION"
log_run_result           "$CONFIG / $BOARD" || exit 1
```

### Globals vs parameters

All four functions use globals for their output (same style as the rest of `lib/common.sh`).
Callers must zero-initialise before calling `parse_serial_output` to avoid stale values
from a prior run (e.g. in a loop). `write_run_status` and `log_run_result` are read-only
consumers of those globals.

### CANARY handling

`parse_serial_output` sets `CANARY_EARLY` (reached/missing/"") unconditionally — it is a
dmesg-level check, not QEMU-specific. `write_run_status` writes `CANARY_EARLY=` to
`vm.status` if non-empty, same as now. The post-boot CANARY warning (lines 235–247 in
current vm.sh) stays in vm.sh because it is conditional on the `CANARY=1` build flag,
which is a build-system concept that board.sh does not use.

### Source path standardisation

```bash
# Before (vm.sh line 6):
. "$(dirname "$0")/common.sh"

# After:
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/lib/common.sh"
```

board.sh will use the same pattern (`lib/board.sh` → `../` → repo root).

---

## Testing Strategy

- **No behaviour change** — `make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS="x86_64 i386"`
  must produce identical `vm.status` and terminal output before and after.
- **CI test** — `tests/ci/test-vm-parser.sh` exercises all four functions directly with
  fixture transcripts. No QEMU required. Runs as part of `make ci-test`.
- **Existing Tier 2 CI** — `make ci-test` must pass unchanged (no regressions in
  report, diff, or other tests that read `vm.status`).

### Fixture transcripts (`tests/ci/fixtures/parser/`)

| Fixture | What it tests |
|---|---|
| `transcript-pass.txt` | BOOT_OK + 3× TEST PASS + 1× TEST FAIL + TEST_DONE → BOOT_STATUS=PASS, PASS_COUNT=3, FAIL_COUNT=1, FAILED_TESTS populated |
| `transcript-panic.txt` | "Kernel panic - not syncing: ..." → PANIC=1, BOOT_STATUS=FAIL, FAIL_REASON contains panic line |
| `transcript-timeout-qemu.txt` | Empty file + exit_code=124 → BOOT_STATUS=FAIL, FAIL_REASON contains "Timeout" |
| `transcript-timeout-board.txt` | Empty file + timeout_occurred=1 → BOOT_STATUS=FAIL, FAIL_REASON contains "Timeout" (board path) |
| `transcript-ktap.txt` | KTAP block with 4 "ok" and 2 "not ok" lines (with ANSI codes + timestamps) → KUNIT_PASS=4, KUNIT_FAIL=2 |
| `transcript-canary.txt` | BOOT_OK + [BOOT_CANARY] + TEST_DONE → CANARY_EARLY=reached |

---

## Testing Commands

```sh
# 1. Verify no behaviour change — identical vm.status and terminal output
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS="x86_64 i386"
# Expected: same PASS/FAIL counts as before the refactor

# 2. Run Tier 2 CI tests including the new parser test
make ci-test
# Expected: all tests pass including tests/ci/test-vm-parser.sh

# 3. Spot-check the new parser test in isolation
bash tests/ci/test-vm-parser.sh
# Expected: all begin_test blocks pass

# 4. Verify shellcheck is clean
shellcheck lib/common.sh lib/vm.sh tests/ci/test-vm-parser.sh
# Expected: no warnings at --severity=warning
```
