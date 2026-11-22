# Harness Analysis Fixes — Plan

Branch: `fix/harness-analysis`
Start date: 2026-08-18

---

## Situation

A staging test run for v7.1.9-rc1 (stable-rc) revealed four issues through manual analysis of
`summary.txt`, dmesg files, and source code review. The issues span the report generator, config
fragments, and the binary rebuild workflow. Two are correctness bugs; two are coverage gaps that
generate noise or silent failures.

---

## Problems to Solve

1. **`lib/report.sh` stale variable bug** — `tests_fail` and `failed_tests` from the outer
   data-gathering loop bleed into subsequent iterations (including build-only configs) and into the
   text rendering loop. Result: "1 failed" appears in the Notes column of every row, including rows
   for passing configs and build-only configs that have no test results.

2. **Stale snapshot binary causes `480_snapshot` failures** — `make bootstrap` is the only command
   that rebuilds `tests/programs/`. On machines where bootstrap runs infrequently (Hetzner staging,
   CI), commits that change `snapshot.c` (or any C test helper) require a manual `make bootstrap`
   to take effect. Without an automatic rebuild trigger in `make all`, the initramfs silently packs
   an outdated binary.

3. **`CONFIG_OF_UNITTEST` missing from deterministic KUnit coverage** — When randomly selected in
   rand500config on riscv (QEMU virt), `CONFIG_OF_UNITTEST` triggers `### dt-test ### FAIL
   of_unittest_check_addr()` for PCIe address ranges incompatible with the QEMU virt device tree.
   This produces spurious FAIL noise. Meanwhile, kunitconfig — the deterministic KUnit profile —
   does not include `CONFIG_OF_UNITTEST`, so this subsystem has no reliable test coverage.

4. **`git pull --rebase` in report.sh causes cascade conflicts in data repo** — `lib/report.sh`
   runs `git pull --rebase --autostash` on `DATA_REPO` before committing a new report. When local
   and remote diverge (many report commits from Hetzner staging vs local machine), git replays
   every commit individually and each `config-archive` commit conflicts on the auto-generated
   index files, producing an interactive rebase with hundreds of manual conflict steps.

5. **rand500config arm64 silently boots 16K/64K page kernels** — `rand500config-arm64.config` is
   missing `CONFIG_ARM64_4K_PAGES=y`. When rand500config randomly enables 16K or 64K page size,
   the kernel silently fails to boot on QEMU virt/cortex-a57 (ARMv8.0-A). The same pin is already
   applied to `randdefconfig-arm64.config` for this exact reason.

---

## Goals

1. `lib/report.sh` text output: "N failed" in Notes appears only for rows with actual test
   failures; build-only and zero-failure rows show nothing or only fail_reason.
2. `make all` automatically rebuilds C test binaries before `initramfs`; stale binaries never
   silently enter the initramfs again.
3. `kunitconfig` runs `CONFIG_OF_UNITTEST=y` deterministically; `randconfig` / `rand500config`
   exclude it (avoid QEMU virt DT noise).
4. `git pull` in `report.sh` never triggers a rebase; data repo always merges.
5. `rand500config` arm64 boots consistently on QEMU virt/cortex-a57.
6. CI test coverage for the report.sh bug and all identified edge cases.

---

## Scope

Files/components changed:
- `lib/report.sh` — fix stale-variable bleed in outer loop (build-only branch) and text rendering
  loop (use per-row ROWS data instead of outer-loop variable); change `git pull --rebase` to
  `--no-rebase` to prevent cascade conflicts in the data repo
- `Makefile` — add `programs` target; insert `$(MAKE) programs || true` before `initramfs` in
  `make all`; add to `.PHONY` and help
- `lib/bootstrap.sh` — add mention of `make programs` as lightweight rebuild path in done message
- `configs/randconfig.config` — add `CONFIG_OF_UNITTEST=n`
- `configs/kunitconfig.config` — add `CONFIG_OF_UNITTEST=y`
- `configs/rand500config-arm64.config` — add `CONFIG_ARM64_4K_PAGES=y`
- `tests/ci/test-report.sh` — add fixture-based CI tests for all identified edge cases

No changes to: `lib/initramfs.sh` (binary injection already correct), `lib/vm.sh`, HTML rendering
path in `report.sh` (already uses per-row `ftests` correctly), `tests/programs/` or `tests/ns/`
source files.

---

## Non-goals

- Adding `CONFIG_OF_UNITTEST` to `kunitrandconfig` (already randomises KUnit modules)
- Triggering a `make programs` rebuild inside `lib/initramfs.sh` (wrong layer — initramfs.sh
  consumes binaries; `make programs` produces them)
- Auto-installing system packages on build machines without explicit `make bootstrap`
- Changing the report output format or column layout
- Writing kernel-level tests for the OF unit test framework

---

## Design decisions

### `make programs` placement: before `initramfs` in `make all`, `|| true`, always runs

Inserting `$(MAKE) programs || true` immediately before `$(MAKE) initramfs || true` in `make all`
ensures binaries are current before they are packed. The `|| true` prevents a C build failure
from blocking the kernel test pipeline — a build error is a development-time problem, not a
pipeline-blocking event. `programs` runs even when `NO_BUILD=1` because `NO_BUILD` suppresses
kernel builds, not helper binary builds.

Alternative considered: make `initramfs` depend on the binary build. Rejected — initramfs.sh
already has many responsibilities; adding `make -C tests/programs` there couples two unrelated
build layers and complicates the `NO_BUILD=1` fast path.

### report.sh fix: two-layer (outer loop + rendering loop)

Two variables bleed independently:
- `tests_fail` and `failed_tests` are not reset in the build-only branch of the outer
  data-gathering loop, so they carry over into subsequent ROWS entries.
- In the text rendering loop, `fail_count=${tests_fail:-0}` uses the outer-loop variable
  instead of per-row data.

Fix layer 1: add `failed_tests=''` and `tests_fail='0'` to the build-only branch so ROWS
always has correct per-row data.

Fix layer 2: replace `fail_count=${tests_fail:-0}` with `if [[ -n $ftests ]]; then read -ra
ftarr <<< "$ftests"; fail_count=${#ftarr[@]}; else fail_count=0; fi` to derive the count from
the per-row `ftests` variable extracted from ROWS.

The HTML rendering loop already uses `ftests` directly (no stale variable) — no change needed.

### CONFIG_OF_UNITTEST: exclude from rand500 noise, add to kunitconfig

`CONFIG_OF_UNITTEST=n` in `configs/randconfig.config` (applied to both randconfig and as the
constraint source for rand500config) eliminates the spurious QEMU virt DT failures in riscv
rand500 runs. `CONFIG_OF_UNITTEST=y` in `configs/kunitconfig.config` moves this coverage to the
deterministic KUnit profile where QEMU virt DT is known good and failures are actionable.

### rand500config arm64 page-size pin: same rationale as randdefconfig

`CONFIG_ARM64_4K_PAGES=y` is the direct parallel of the pin already in
`randdefconfig-arm64.config`. Both configs start from a base that may enable 16K/64K pages,
and both target QEMU virt/cortex-a57 which requires 4K.

---

## Testing strategy

- **report.sh stale variable** — Fixture-based CI test in `tests/ci/test-report.sh`: two-row
  run where row 1 has 1 failed test and row 2 has none; assert "1 failed" appears exactly in
  the first row's Notes and not the second's. Second test: build-only config follows a failing
  bootable config; assert no bleed into build-only row.
- **fail_reason in Notes** — Fixture: boot FAIL with FAIL_REASON=timeout; assert Notes shows
  the reason string.
- **cfg-fixed in Notes** — Fixture: CONFIG_CORRECTED=1 in build.status; assert Notes shows
  "cfg-fixed".
- **HTML Notes consistency** — Fixture: 1 failed test with FAILED_TESTS set; assert HTML output
  contains the failed test name span.
- **Config changes** — Verified by `make lint` (shellcheck, inventory, context size).
  CONFIG_OF_UNITTEST presence in kunitconfig confirmed by grep. Functional boot verification
  requires a full `make smoke` run (not automated in CI due to kernel+QEMU requirement).
- **make programs** — Verified by `make programs` running successfully on the development machine.
  No CI test for binary compilation (compiler/arch deps not in CI).

---

## Testing commands

```sh
# Always run before pushing
make dev-test
# Expected: exit 0, ≥50% decision paths covered within time budget

# 1. Lint passes (shellcheck, context sizes, design doc present)
make lint
# Expected: exit 0, no errors

# 2. CI harness self-tests (includes new report.sh tests)
make ci-test
# Expected: exit 0, all tests pass

# 3. Verify CONFIG_OF_UNITTEST in kunitconfig and not in rand500config
grep CONFIG_OF_UNITTEST configs/kunitconfig.config configs/randconfig.config
# Expected: kunitconfig.config:CONFIG_OF_UNITTEST=y
#           randconfig.config:CONFIG_OF_UNITTEST=n

# 4. Verify arm64 page-size pin added to rand500config-arm64
grep ARM64_4K_PAGES configs/rand500config-arm64.config configs/randdefconfig-arm64.config
# Expected: both files contain CONFIG_ARM64_4K_PAGES=y

# 5. Rebuild programs target (no kernel build needed)
make programs
# Expected: exit 0, tests/programs/ and tests/ns/ build clean

# 6. Spot-check report output (no stale "1 failed") — full pipeline on tinyconfig only
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64
# Expected: Notes column shows nothing for passing configs; no "1 failed" on build-only rows
```
