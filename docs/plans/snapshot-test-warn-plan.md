# snapshot: suppress test-mode WARN taint from boot health count — Plan

Branch: `fix/snapshot-test-warn`
Start date: 2026-08-19

---

## Situation

`kunitconfig/arm64` fails `480_snapshot` with `ISSUES: 1` on any kernel that boots with
KUnit enabled plus `CONFIG_OF_UNITTEST=y`. The device-tree unit test deliberately triggers
`WARN_ONCE()` via a refcount underflow in `of_unittest_lifecycle()` (guarded by
`CONFIG_OF_DYNAMIC`, which arm64 defconfig sets via `CONFIG_OF_OVERLAY=y`). This sets
`TAINT_WARN` (bit 9) in `/proc/sys/kernel/tainted`. `snapshot.c` counts bit 9 as a boot
health issue (`is_issue=1`), causing `ISSUES: 1` → `480_snapshot` fails.

---

## Problems to Solve

1. **False positive boot health issue** — intentional WARNs from kernel self-tests
   (of_unittest, KUnit) set TAINT_WARN and are counted as real kernel misbehaviour.
2. **arm64-only failure** — x86_64/i386 never reach OF_UNITTEST (OF_EARLY_FLATTREE
   not in defconfig); riscv has no OF_OVERLAY so no OF_DYNAMIC → no WARN. Only arm64
   defconfig ships `CONFIG_OF_OVERLAY=y`, making this an arch-specific false positive.

---

## Goals

1. `480_snapshot` passes on `kunitconfig/arm64` when `CONFIG_OF_UNITTEST=y` is active.
2. Real kernel WARNs (hardware faults, driver bugs) still count as issues.
3. `CONFIG_OF_UNITTEST=y` stays in `configs/kunitconfig.config` — DT coverage preserved.

---

## Scope

Files/components changed:
- `tests/programs/snapshot/snapshot.c` — suppress WARN (bit 9) from `issue_count` when
  TEST (bit 18) is also set; TEST is set by both KUnit and of_unittest to signal
  intentional test-mode operation
- `tests/programs/snapshot/bin/` — rebuilt binaries (all 4 arches)

No changes to: `configs/kunitconfig.config`, any test scripts, Makefile, lib scripts.

---

## Non-goals

- Suppressing WARN unconditionally — real hardware/driver WARNs must still be caught.
- Changing the taint flag table (is_issue values) — bit 18 already has `is_issue=0`.
- Fixing the underlying of_unittest WARN — it is intentional and documented in Kconfig.

---

## Design decisions

### Suppress WARN only when TEST is co-set

The Linux kernel documentation and `of_unittest` Kconfig help text both explicitly state
that running `of_unittest` "will cause ERROR and WARNING messages to print on the console"
and that it "taints the kernel with TAINT_TEST". TAINT_TEST (bit 18) is the kernel's own
signal that the kernel is running in intentional self-test mode and that diagnostic noise
(including WARNs) should be expected.

Alternative considered: lower TAINT_WARN's `is_issue` to 0 permanently — rejected because
WARN on a production kernel (no TEST taint) is a genuine indicator of kernel misbehaviour
and should remain visible.

Alternative considered: remove `CONFIG_OF_UNITTEST=y` from kunitconfig.config — rejected
because of_unittest only actually runs on arm64 in QEMU (the one arch with OF_DYNAMIC);
removing it would eliminate all device-tree unit test coverage from kunitconfig.

---

## Testing strategy

- **Regression gate** — `make dev-test` must pass (>70% decision paths, ≤6 min).
- **Binary rebuild** — `make -C tests/programs` must compile clean for all 4 arches.
- **Functional** — full `kunitconfig/arm64` QEMU run needed to confirm; approximated
  here by checking snapshot output logic and the taint suppression path in code review.

---

## Testing commands

```sh
# Always run before pushing any branch
make dev-test
# Expected: exit 0, >70% decision paths

# Rebuild snapshot binary for all arches
make -C tests/programs
# Expected: no errors; bin/x86_64/snapshot bin/i686/snapshot bin/aarch64/snapshot bin/riscv64/snapshot updated

# Shellcheck (pre-push will run this automatically)
make lint
# Expected: exit 0

# Full kunitconfig run (optional — takes 20+ min per arch)
make all NO_FETCH=1 CONFIGS=kunitconfig ARCHS=arm64
# Expected: 480_snapshot PASS, ISSUES: 0
```
