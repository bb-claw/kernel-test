# Snapshot Issue Detection — Plan

Branch: `feat/snapshot-issue-detection`
Start date: 2026-08-16
Status: IN PROGRESS

---

## Situation

The snapshot binary collects 26 system fields at boot and writes `/tmp/snapshot.txt`.
It exits 0 when no infrastructure failures occurred (malloc, gethostname, uname, klogctl).
This makes it a good information collector but a passive one — it cannot signal that the
kernel under test has problems.

Adding issue detection turns snapshot into a dual-purpose tool: information collector +
health probe. The exit code becomes a machine-readable verdict that callers (480_snapshot.sh,
future CI steps) can check without parsing the output file.

---

## Goals

1. Expand `dump_dmesg()` to scan 4 additional patterns: RCU stalls, hung tasks, OOM kills,
   soft/hard lockups.
2. Decode the TAINTED bitmask into short kernel flag names (all 18 bits from
   `Documentation/admin-guide/tainted-kernels.rst`).
3. Count detected issues across all fields; emit an aligned `ISSUES: N` line before
   `snapshot_ok=1`.
4. Exit with `issue_count` clamped to 254; exit 255 for infrastructure failures.
5. Update `480_snapshot.sh` to re-run snapshot, capture exit code, and FAIL when nonzero.
6. Update `test-snapshot.sh` to call `dmesg -C` before the behavioral test so the exit 0
   assertion remains valid on any host.

---

## Scope

Files changed:
- `tests/programs/snapshot/snapshot.c` — dmesg patterns, taint decode, issue_count, exit code
- `tests/custom/480_snapshot.sh` — re-run + exit code check + snapshot-recheck.txt
- `tests/ci/test-snapshot.sh` — dmesg -C before behavioral test; assertion update

No changes to: `lib/initramfs.sh`, `lib/bootstrap.sh`, `lib/report.sh`, other test scripts.

---

## Exit Code Design

| Exit code | Meaning |
|---|---|
| 0 | Clean: no infrastructure errors, no detected issues |
| 1–254 | `issue_count` detected issues (clamped to 254) |
| 255 | Infrastructure failure: malloc OOM, gethostname, uname, or klogctl error |

The two failure paths are separated so callers can distinguish "snapshot couldn't run"
(255) from "snapshot ran and found N problems" (1–254).

Current `fail_count` → exit 255 path is unchanged. `issue_count` is a new counter,
incremented only by detected kernel health issues.

---

## Issue Count

The following conditions increment `issue_count` (warnings excluded — too common on
defconfig kernels from driver probes and deprecated API usage):

| Source | Condition | Increment |
|---|---|---|
| TAINTED | value nonzero | +1 (flat, regardless of which bits) |
| DMESG oops | `"Oops:"` per line | +count |
| DMESG bugs | `"BUG:"` per line | +count |
| DMESG panics | `"Kernel panic"` per line | +count |
| DMESG rcu_stall | `"self-detected stall"` per line | +count |
| DMESG hung_task | `"blocked for more than"` per line | +count |
| DMESG oom_kill | `"Out of memory: Killed process"` per line | +count |
| DMESG lockup | `"BUG: soft lockup"` or `"BUG: hard lockup"` per line | +count |
| DMESG kunit_fail | `"not ok "` per line | +count |

`dump_dmesg()` is called before `dump_tainted()` in the output order — the DMESG
counters are tallied inside `dump_dmesg()`, then `dump_tainted()` adds its +1 if nonzero.
Both write into a shared `issue_count` global.

---

## DMESG Field (expanded format)

```
DMESG: oops=0 bugs=0 warns=3 panics=0 rcu_stall=0 hung_task=0 oom_kill=0 lockup=0 kunit_fail=0
```

`warns` is retained for information but does NOT increment `issue_count`. All new
counters use the existing null-terminated line scan loop — no change to the loop
structure, just additional `strstr()` calls per line.

`str[]` buffer grows from 160 to 220 bytes to accommodate the new fields.

---

## TAINTED Field (decoded)

All 18 taint bits decoded via a static lookup table (bit index → short name).
Multiple active bits produce a space-separated list in parentheses.

| Bit | Char | Name |
|---|---|---|
| 0 | P | PROPRIETARY_MODULE |
| 1 | F | FORCED_MODULE |
| 2 | S | CPU_OUT_OF_SPEC |
| 3 | R | FORCED_RMMOD |
| 4 | M | MACHINE_CHECK |
| 5 | B | BAD_PAGE |
| 6 | U | USER |
| 7 | D | DIE |
| 8 | A | OVERRIDDEN_ACPI_TABLE |
| 9 | W | WARN |
| 10 | C | STAGING_DRIVER |
| 11 | I | FIRMWARE_WORKAROUND |
| 12 | O | OOT_MODULE |
| 13 | E | UNSIGNED_MODULE |
| 14 | L | SOFTLOCKUP |
| 15 | K | LIVEPATCH |
| 16 | X | AUX_TAINT |
| 17 | N | RANDSTRUCT |

Clean kernel output: `TAINTED: 0`
Single bit: `TAINTED: 16384 (SOFTLOCKUP)`
Multiple bits: `TAINTED: 3 (PROPRIETARY_MODULE FORCED_MODULE)`

When tainted, `issue_count += 1` (flat — one issue regardless of how many bits).

---

## ISSUES Field

New aligned field, always emitted before `snapshot_ok=1`:

```
      ISSUES: 0
snapshot_ok=1
```

or when problems are detected:

```
      ISSUES: 3
snapshot_ok=1
```

`snapshot_ok=1` is always printed as long as the binary ran to completion (regardless
of issue_count). It marks "snapshot did not crash mid-run", not "kernel is clean".

---

## 480_snapshot.sh Changes

Current final block:
```sh
if grep -q "^snapshot_ok=1" "$SNAP_FILE"; then
    ok "snapshot_ok=1 (clean exit)"
else
    fail "snapshot_ok=1 missing"
fi
```

New block — re-run snapshot and check exit code:
```sh
# Re-run snapshot to get the issue-detection exit code.
# Output goes to a separate file so the boot-time /tmp/snapshot.txt is preserved.
"$SNAP_BIN" > /tmp/snapshot-recheck.txt 2>/dev/null
snap_exit=$?
if [ "$snap_exit" -eq 0 ]; then
    ok "snapshot: no issues detected (exit 0)"
else
    if [ "$snap_exit" -eq 255 ]; then
        fail "snapshot: infrastructure failure (exit 255)"
    else
        fail "snapshot: $snap_exit issue(s) detected (see /tmp/snapshot-recheck.txt)"
    fi
fi
```

Note: `if out=$(cmd); then` is a Toybox sh bug (assignment always exits 0). The above
uses a file redirect so `$?` captures the real exit code — consistent with the existing
pattern in other test scripts.

`/tmp/snapshot-recheck.txt` is written so the post-test run is available for inspection
alongside the boot-time snapshot, without overwriting `/tmp/snapshot.txt`.

The `snapshot_ok=1` check is removed from `480_snapshot.sh` since the exit code now
carries the definitive verdict. The field is still present in the output for humans
reading the file directly.

---

## test-snapshot.sh Changes

The behavioral section currently asserts `exit 0`. This remains valid — but requires
the host ring buffer to be clean when snapshot runs. Add `dmesg -C` before the run:

```sh
--- st-behavioral (existing section name)
# Clear host ring buffer so pre-existing warnings don't trip issue detection.
dmesg -C 2>/dev/null || true
snapshot > /tmp/snapshot-host.txt 2>/dev/null
assert_exit_0 "exit 0 (no issues after dmesg clear)"
assert_present "snapshot_ok=1"
assert_present "ISSUES: 0"
```

`dmesg -C` requires `CAP_SYSLOG`. In CI environments where that capability is absent,
`dmesg -C` exits non-zero — the `|| true` handles this, and `ISSUES:` may be nonzero,
so the exit 0 assertion would need to be relaxed in that case. The design doc leaves
this as a known edge case; the CI self-test environment (local machine) has the
capability.

---

## Assertion count delta (test-snapshot.sh)

Current: 35 assertions.
Expected after this PR: ~40 assertions (+ISSUES field present, +ISSUES: 0 on clean host,
+taint decode format check, +new DMESG counter fields check).

---

## Future Direction: Report Integration

`report.sh` copies `vm.status` per (config, arch). A future extension could:

- Parse the `ISSUES: N` line from the archived `/tmp/snapshot.txt` (via `dmesg.txt`
  which contains the full serial output, or a dedicated artifact)
- Add an `ISSUES` column to `summary.html`
- Color-code rows where `ISSUES > 0`
- Cross-run diff: flag when a (config, arch) goes from `ISSUES: 0` to `ISSUES: N`

The `ISSUES: N` count-only format is chosen specifically to make this grep-friendly:
```sh
grep "^      ISSUES:" dmesg-defconfig-x86_64.txt | awk '{print $2}'
```

---

## Testing Commands

```sh
# Build
make -C tests/programs/snapshot

# CI (35+ assertions)
make ci-test

# Tinyconfig — snapshot exits 0, ISSUES: 0
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS=x86_64

# Defconfig — snapshot exits 0, ISSUES: 0, all fields present
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=defconfig ARCHS=x86_64

# Smoke — all 8 combos
make smoke NO_FETCH=1
```
