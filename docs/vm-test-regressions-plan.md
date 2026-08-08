# VM Test Script Regressions — Plan

Branch: `fix/vm-test-regressions`
Start date: 2026-08-08

---

## Situation

Testing on stable v7.1.7 (`make local`, `make smoke`, `make ns-smoke`) revealed five classes of
failures in the VM test suite. Four are Toybox sh parsing bugs; one is a missing infrastructure
guard. Together they cause 290/300/320/330 to fail on any config where the first `if` branch is
taken, 380 to always fail on arm64, and 290–360 to incorrectly run (and produce misleading
output) on configs that do not include the namespace kernel options.

---

## Problems to Solve

1. **elif bug — 290/300/320/330** — Toybox sh 0.8.9: when `if...elif...else...fi` is used and
   the *first* `if` condition is TRUE, both the `if` body and the `else` body execute. Confirmed
   by dmesg: `FAIL: UTS: hostname not isolated (got 'ns-test-290')` — the value is correct, but
   the else branch fires anyway. Affects all four tests that probe namespace isolation via
   `unshare`.

2. **line-continuation bug — 380** — Toybox sh: `\<newline>` at the end of a command inside a
   pipeline (`grep -q 'pat' \`) passes trailing whitespace as a file argument to grep, causing
   `grep:  : No such file or directory` and a forced non-zero exit. Result: FP and NEON always
   reported absent on arm64 even though they are present in `/proc/cpuinfo`.

3. **missing infrastructure guard — 290–360** — Tests 290–360 carry a header skip guard only for
   the `ns-*` C binaries, not for the namespace kernel options themselves. On non-ns-variant
   configs (defconfig, kunitconfig, localconfig, etc.) the tests partially run, produce confusing
   partial output, or fail with "inode unchanged" on features that aren't enabled.

4. **missing markers for 390/400/410** — Tests 390 (watchdog), 400 (perf-events), 410 (arena)
   currently do individual per-feature probing but do not benefit from a unified
   infrastructure-ready check. Retrofitting them with the same marker pattern makes the
   skip logic consistent and forward-compatible.

5. **report Notes column line wrap** — `lib/report.sh` writes the failed-test list as an
   unbounded `%s` column in the text summary table. On runs with many failures the Notes field
   wraps across terminal lines, obscuring the table structure.
   *(Scope TBD — may move to a separate branch.)*

---

## Goals

1. 290/300/320/330 pass on all configs that include the namespace kernel options.
2. 380 passes on arm64 QEMU (FP and NEON correctly detected).
3. 290–360 skip cleanly (single skip line, no partial output) on non-ns-variant configs.
4. 390/400/410 use the same marker pattern (double-guard: marker + runtime probe).
5. `memory/code-quality.md` updated with both Toybox sh bugs.
6. Tier 2 CI (test-ns-*.sh) passes after all changes.

---

## Scope

Files changed:
- `tests/custom/290_ns-uts-ipc.sh` — replace `if/elif/else/fi` with nested `if/else/fi`; add marker guard
- `tests/custom/300_ns-pid.sh` — same elif fix; add marker guard
- `tests/custom/320_ns-net.sh` — same elif fix; add marker guard
- `tests/custom/330_ns-user.sh` — same elif fix; add marker guard
- `tests/custom/310_ns-mount.sh` — add marker guard (no elif to fix)
- `tests/custom/340_ns-cgroup.sh` — add marker guard
- `tests/custom/350_ns-time.sh` — add marker guard
- `tests/custom/360_ns-setns.sh` — add marker guard
- `tests/custom/380_arm64-features.sh` — replace `cmd | grep \ && ok || fail` with `if cmd | grep; then ok; else fail; fi`
- `tests/custom/390_watchdog.sh` — add marker guard (double-guard pattern)
- `tests/custom/400_perf-events.sh` — add marker guard
- `tests/custom/410_arena-memory.sh` — add marker guard
- `lib/initramfs.sh` — per-(config,arch); write `/tests/<category>-enabled` marker files per binary/config availability
- `lib/vm.sh` — update INITRAMFS path to `build/initramfs-$CONFIG-$ARCH.cpio.gz`
- `lib/report.sh` — Notes column: "N failed" count in table; failed test names in block below
- `memory/code-quality.md` — document elif bug + line-continuation bug in Toybox pitfalls list
- `tests/ci/test-ns-scripts.sh`, `test-ns-initramfs.sh`, `test-watchdog-script.sh` — update CI tests to cover marker approach

No changes to: `lib/build.sh`, `lib/common.sh`.

---

## Non-goals

- Serial-capture hardening (Phase 7) — separate branch, deferred.
- Adding new test slots (420+) — separate branch.

---

## Design Decisions

### Marker files under `/tests/`

A set of empty marker files is written into the initramfs by `lib/initramfs.sh` at build time.
Each marker indicates that the corresponding test infrastructure is ready inside the VM:

| Marker | Written when |
|---|---|
| `/tests/ns-enabled` | ns-* binaries installed (ns_count > 0 after `tests/ns/bin/$ARCH` copy loop) |
| `/tests/perf-enabled` | `tests/programs/perf-event/bin/perf-event-<arch>` binary is present |
| `/tests/arena-enabled` | `tests/programs/arena-test/bin/arena-test-<arch>` binary is present |
| `/tests/watchdog-enabled` | `CONFIG_WATCHDOG=y` found in `build/$CONFIG-$ARCH/.config` |

Tests check the marker as their *first* guard:
```sh
[ -f /tests/ns-enabled ] || { skip "ns not enabled for this config"; exit 0; }
```
The existing runtime check (binary present, `/dev/watchdog` present, etc.) follows as a
second guard. This "double-guard" pattern cleanly separates infrastructure readiness from
kernel feature availability.

Single cpio — all markers baked into the per-(config, arch) initramfs; no overlay layer.

### elif fix approach

Replace all `if...elif...else...fi` blocks where the elif discriminates on an empty/error
case and the else is a `fail` branch, with nested `if/else/fi`:
```sh
# Before (broken):
if [ condition ]; then ok "..."
elif [ -z "$var" ]; then skip "..."
else fail "..."
fi

# After (correct):
if [ condition ]; then
    ok "..."
else
    if [ -z "$var" ]; then skip "..."
    else fail "..."
    fi
fi
```

### Line-continuation fix for 380

Replace:
```sh
printf '%s' "$fp" | grep -q ' fp ' \
    && ok "FP present" || fail "FP absent"
```
With:
```sh
if printf '%s' "$fp" | grep -q ' fp '; then
    ok "FP present"
else
    fail "FP absent (ARMv8-A regression)"
fi
```
This avoids `\<newline>` inside a pipeline, which Toybox sh passes as a whitespace
file argument to the command preceding the continuation.

---

## Resolved Questions

1. ✓ Marker naming: `/tests/ns-enabled` (simpler, consistent with others)
2. ✓ Report Notes fix included in this branch (not deferred)
3. ✓ watchdog-enabled: `.config` grep for `CONFIG_WATCHDOG=y` in per-(config,arch) build dir
4. ✓ Line-continuation bug documented in `memory/code-quality.md`

---

## Testing Strategy

- **Tier 2 CI** — `make ci-test` covers test-ns-configs.sh, test-ns-build.sh,
  test-ns-initramfs.sh, test-ns-scripts.sh
- **VM smoke** — `make smoke NO_FETCH=1 CONFIGS=tinyconfig ARCHS=arm64` verifies 380 fix
- **NS smoke** — `make ns-smoke NO_FETCH=1` verifies marker approach + elif fixes on
  ns-variant configs
- **Non-ns configs** — `make smoke NO_FETCH=1 CONFIGS=kunitconfig ARCHS=arm64` verifies
  290–360 skip cleanly

---

## Testing Commands

```sh
# 1. Tier 2 CI
make ci-test
# Expected: all test-*.sh pass

# 2. Verify 380 fix (arm64 FP/NEON)
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=arm64
# Expected: 380_arm64-features PASS

# 3. Verify elif fix + marker skip on non-ns config
make all NO_FETCH=1 CONFIGS=kunitconfig ARCHS=x86_64
# Expected: 290–360 all show "skip: ns not enabled" (one line each)

# 4. Verify elif fix passes on ns-variant config
make ns-smoke NO_FETCH=1
# Expected: 290–360 all PASS on tinynsconfig + kunitnsconfig
```
