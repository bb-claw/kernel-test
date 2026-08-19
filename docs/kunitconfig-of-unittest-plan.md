# kunitconfig OF_UNITTEST removal — Plan

Branch: `fix/kunitconfig-of-unittest`
Start date: 2026-08-19

---

## Situation

PR #59 (`fix/harness-analysis`, merged 2026-08-18 19:01 UTC) added `CONFIG_OF_UNITTEST=y` to
`configs/kunitconfig.config`, moving device-tree unit test coverage from the random pool (where it
caused spurious FAIL noise on riscv QEMU) to the deterministic KUnit profile.  The assumption was
that QEMU virt DT is "known good" for of_unittest on arm64.  Hetzner staging ran kunitconfig/arm64
at 19:51 UTC and `480_snapshot` failed: `of_unittest` triggered a `WARN()` in kernel DT code on
arm64 QEMU, setting TAINTED_WARN (bit 9), which `snapshot.c` classifies as `is_issue=1`
→ `ISSUES: 1`.  x86_64 passes because x86_64 QEMU has no real device tree and `of_unittest`
runs in a degenerate mode that doesn't reach the WARN paths.

---

## Problems to Solve

1. **kunitconfig/arm64 → 480_snapshot FAIL** — `CONFIG_OF_UNITTEST=y` triggers a kernel WARN()
   on arm64 QEMU virt that was not triggered on x86_64, causing a false boot-health failure every
   run regardless of kernel version.

---

## Goals

1. `kunitconfig/arm64` boots cleanly with `ISSUES: 0` in `snapshot.txt`.
2. `480_snapshot` passes on all kunitconfig × arch combinations.
3. `CONFIG_OF_UNITTEST` remains excluded from randconfig/rand500config (already pinned =n in
   PR #59).

---

## Scope

- `configs/kunitconfig.config` — remove `CONFIG_OF_UNITTEST=y` (3-line section)

No changes to: `configs/randconfig.config` (OF_UNITTEST=n stays), `snapshot.c`,
`tests/custom/480_snapshot.sh`, memory files.

---

## Non-goals

- Adding `CONFIG_OF_UNITTEST` to a kunitconfig-arm64.config arch overlay (more complex; the
  test adds no KUnit coverage metrics and is not worth the per-arch maintenance)
- Changing snapshot.c taint classification (TAINTED_WARN as is_issue=1 is correct for detecting
  unexpected kernel WARNs at boot; the fix is to not trigger the WARN, not to ignore it)
- Reporting the of_unittest WARN upstream (not blocked; track separately if desired)

---

## Design decisions

### Remove unconditionally vs arm64-only override

`of_unittest` is NOT a KUnit test — it uses a separate `device_initcall_sync` mechanism and
does not contribute to `KUNIT_PASS`/`KUNIT_FAIL` metrics. It was added to kunitconfig for
opportunistic DT coverage but has no stable behavior guarantee across QEMU virt DTBs or kernel
versions.  Keeping it only on x86_64 via an arch overlay adds complexity for no measured benefit.
Removing it entirely is the correct scope decision.

---

## Testing strategy

- **kunitconfig/arm64** — full `make all CONFIGS=kunitconfig ARCHS=arm64` to verify
  `480_snapshot` passes and ISSUES: 0 in snapshot.txt.
- **kunitconfig/x86_64** — verify no regressions in KUNIT_PASS count (of_unittest contributed
  0 to this metric since it is not parsed as KTAP).
- **make lint** — confirms shellcheck + inventory + context size clean.
- **make dev-test** — branch gate.

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, >70% decision paths

# 1. Verify CONFIG_OF_UNITTEST absent from kunitconfig
grep OF_UNITTEST configs/kunitconfig.config configs/randconfig.config
# Expected: only randconfig.config:CONFIG_OF_UNITTEST=n

# 2. Confirm kunitconfig/arm64 snapshot passes (requires kernel build)
make all NO_FETCH=1 CONFIGS=kunitconfig ARCHS=arm64
# Expected: boot PASS, 480_snapshot PASS, ISSUES: 0
```
