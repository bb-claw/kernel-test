# chore: bump Toybox 0.8.14 → 0.8.15 — Plan

Branch: `chore/bump-toybox-0.8.15`
Start date: 2026-11-21

---

## Situation

Toybox 0.8.15 was released on 2026-10-03. The harness pins Toybox at
`TOYBOX_VERSION ?= 0.8.14` (Makefile) and ships matching static binaries for
x86_64, i686, aarch64, and riscv64 in the `cache/` directory. The version is
also hardcoded as a fallback in `lib/bootstrap.sh` and as a fixture in three
CI test scripts.

---

## Problems to Solve

1. **Stale Toybox pin** — 0.8.14 misses bug fixes shipped in 0.8.15.
2. **Silent stale cache** — `lib/download-toybox.sh` checks file existence
   only; after a version bump `make bootstrap` silently keeps the old binary
   because `cache/toybox-x86_64` already exists. No re-download occurs without
   manual intervention.
3. **New dmesg warning on missing `/dev/kmsg`** — Toybox 0.8.15 dmesg warns
   to stderr when it cannot open `/dev/kmsg` (instead of silently falling back
   to klogctl). The initramfs devtmpfs-fallback block creates `/dev/console`
   and `/dev/null` but not `/dev/kmsg`, so this warning appears on serial
   output in minimal configs (tinyconfig, allnoconfig).

---

## Goals

1. All four Toybox binaries updated to 0.8.15 after `make bootstrap`.
2. Version bump on its own triggers a re-download — no manual cache clearing
   needed.
3. No new dmesg warnings on serial output due to missing `/dev/kmsg`.

---

## Scope

Files changed:
- `Makefile` — `TOYBOX_VERSION ?= 0.8.14` → `0.8.15`
- `lib/bootstrap.sh` — fallback default `:-0.8.14` → `:-0.8.15`
- `lib/download-toybox.sh` — add per-arch version stamp
  (`cache/.toybox-<arch>-version`); re-download when stamp ≠ TOYBOX_VERSION
- `lib/initramfs.sh` — add `mknod /dev/kmsg c 1 11` to devtmpfs-fallback block
- `tests/ci/test-makefile-defaults.sh` — two new tests (see Testing strategy)
- `tests/ci/test-report.sh` / `test-combined-report.sh` /
  `test-extended-perf-report.sh` — fixture consistency update (0.8.14 → 0.8.15)
- `tests/custom/README.md` — version reference

No changes to: test scripts, VM configurations, kernel configs.

---

## Non-goals

- Investigating `090_check-clocksource` regression in v7.4-rc3 — that test
  fails because the kernel no longer emits clocksource registration messages in
  tinyconfig; it is unrelated to the Toybox bump (030_check-dmesg passes
  confirming klogctl fallback works).
- Bumping the GCC version in Ansible (tracked separately).

---

## Design decisions

### Version stamp in download-toybox.sh

The download script stores `cache/.toybox-<arch>-version` after each
successful download. On subsequent `make bootstrap` calls: if the file exists
and contains the current version → skip. If the version changed → delete the
old binary and re-download. Per-arch stamps allow partially-updated states to
be retried cleanly.

### /dev/kmsg in initramfs devtmpfs-fallback

`/dev/kmsg` (major 1 minor 11) is the modern kernel log device — preferred
over the klogctl syscall by all recent tools. When devtmpfs mounts the fix is
automatic; when it isn't available (tinyconfig/allnoconfig), the fallback block
must create it alongside `/dev/console` and `/dev/null`.

### 090_check-clocksource failure (resolved by /dev/kmsg fix)

0.8.15 dmesg uses `/dev/kmsg` as its primary interface; when absent it falls
back to klogctl, but klogctl does not surface early-boot ring-buffer entries
(the clocksource registration message happens before userspace starts). Once
`/dev/kmsg` is created in the initramfs devtmpfs-fallback block, dmesg reads
from `/dev/kmsg` and the full ring buffer — including clocksource lines — is
available again. Test 090 passes. `030_check-dmesg` passed even without
`/dev/kmsg` because it only checks for "Linux version" which survives in the
klogctl partial view.

---

## Testing strategy

**TDD seam: `test-makefile-defaults.sh`**
- `TOYBOX_VERSION is 0.8.15 in Makefile` — explicit version assertion; will
  fail again on the next bump until the test is updated (intentional sentinel)
- `TOYBOX_VERSION is consistent between Makefile and bootstrap.sh` — catches
  drift between the two version pins

**CI suite:** `make ci-test` — 48 tests, all pass after bump.
**Lint:** `make lint` — shellcheck, inventory, context-size checks all pass.
**VM test:** `make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64` — 52/52
tests pass including `090_check-clocksource` (fixed by `/dev/kmsg` addition).

---

## Testing commands

```bash
# 0. Lint + CI tests (runs on: laptop)
make lint && make ci-test
# Expected: lint ok, ci-test 48 passed 0 failed

# 1. Version-specific tests (runs on: laptop)
bash tests/ci/test-makefile-defaults.sh
# Expected: 25 passed 0 failed (includes 2 new TOYBOX_VERSION tests)

# 2. Full pipeline smoke (runs on: laptop — requires kernel tree)
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64
# Expected: 51/52 tests pass; 090_check-clocksource known fail (v7.4-rc3)

# 3. Verify stamp-based re-download (runs on: laptop)
rm cache/toybox-x86_64 cache/.toybox-x86_64-version
TOYBOX_VERSION=0.8.15 CACHE_DIR=cache bash lib/download-toybox.sh x86_64
# Expected: downloads 0.8.15, writes stamp
TOYBOX_VERSION=0.8.15 CACHE_DIR=cache bash lib/download-toybox.sh x86_64
# Expected: "already cached" — no download

# 4. Verify stale-cache re-download (runs on: laptop)
echo "0.8.14" > cache/.toybox-x86_64-version
TOYBOX_VERSION=0.8.15 CACHE_DIR=cache bash lib/download-toybox.sh x86_64
# Expected: "version mismatch (cached 0.8.14 → 0.8.15), re-downloading"
```
