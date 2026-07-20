# kconfig-build — Plan

Branch: `feat/kconfig-build`
Start date: 2026-07-20

---

## Situation

`kconfig-check` (feat/kconfig-check) finds candidate missing-select bugs via
static analysis. `kconfig-build` complements it by exhaustively building and
booting every config option in a subsystem, using full kernel images through the
existing pipeline. It also serves as a standalone verification tool: given a
subsystem, prove which driver options actually fail to build or boot, and archive
the results like any other test run.

---

## Problems to Solve

1. **No exhaustive coverage** — rand500config samples randomly; a missing select
   may not be hit for many runs. Exhaustive per-option builds guarantee coverage.
2. **Verification gap** — `kconfig-check` static candidates need build confirmation.
   `kconfig-build` provides that systematically for an entire subsystem.
3. **No subsystem-scoped build profile** — existing profiles (rand500config,
   defconfig) are not scoped to a single subsystem. There is no way to say
   "build and boot every pinctrl driver option" in one command.

---

## Goals

1. `make kconfig-build SUBSYSTEM=pinctrl` enumerates all `config <NAME>` entries
   in `drivers/<subsystem>/Kconfig`, generates one `.config` per entry
   (tinyconfig + bootability fragment + that single option), builds and boots
   each, and archives results.
2. `DRY_RUN=1` prints the full list of configs × archs that would run, with a
   total count, without building anything.
3. Results are archived under a new profile name `randkconfigconfig` using the
   existing config-archive mechanism.
4. All three architectures (x86_64, i386, arm64) are tested by default,
   overridable with `ARCHS=`.

---

## Scope

Files/components changed:
- `scripts/kconfig-enumerate.sh` — enumerates config entries from a subsystem
  Kconfig file; shared utility, usable by kconfig-check too
- `lib/build-kconfig.sh` — drives per-option build loop; called by Makefile
- `Makefile` — new `kconfig-build` target + `randkconfigconfig` profile support
- `configs/randkconfigconfig.config` — bootability fragment (same as
  rand500config.config; symlink or copy)
- `CLAUDE.md` — update Key files table and CONFIGS list

No changes to: `lib/build.sh`, `lib/vm.sh`, `lib/report.sh`, `scripts/config-archive.sh`
(those work on the generated configs automatically).

---

## Non-goals

- Booting every single possible kernel config option (only subsystem-scoped)
- Parallel builds across options (sequential for now; can be added later)
- Integration with `kconfig-check` output (they are independent; the user
  decides whether to run one or both)
- Object-only builds (full kernel images only, as per design decision)

---

## Design decisions

### Config profile name: `randkconfigconfig`

Extends the existing profile naming convention. Treated as a first-class profile
by `make config-archive` so results land in `configs/archive_failed/` and
`configs/archive_passed/` with the filename prefix
`kconfig-randkconfigconfig-<arch>-<version>-<sha256>[-FAIL_REASON].config`.

Not added to the default `CONFIGS` list — only runs when explicitly requested
via `make kconfig-build SUBSYSTEM=`.

### Base config: tinyconfig + bootability fragment

Same as rand500config: `tinyconfig` as base, then
`configs/rand500config.config` bootability fragment applied last to ensure the
kernel boots in QEMU. One additional step: `scripts/config --enable CONFIG_<NAME>`
for the driver option under test, then `olddefconfig`.

### Exhaustive enumeration

`scripts/kconfig-enumerate.sh <subsystem>` parses
`$KERNEL_TREE/drivers/<subsystem>/Kconfig` and outputs one `CONFIG_<NAME>` per
line for every `^config <NAME>` entry. Output is consumed by
`lib/build-kconfig.sh` in a loop.

This covers all entries including those with `depends on ARCH_FOO` — if they
fail to build on a mismatched arch, that is recorded as a build failure (expected
and filtered in the report).

### Dry-run mode

`DRY_RUN=1` causes `lib/build-kconfig.sh` to print:

```
[DRY_RUN] CONFIG_PINCTRL_AT91        x86_64
[DRY_RUN] CONFIG_PINCTRL_AT91        i386
[DRY_RUN] CONFIG_PINCTRL_AT91        arm64
[DRY_RUN] CONFIG_PINCTRL_BCM2835     x86_64
...
[DRY_RUN] Total: 42 configs × 3 archs = 126 builds
```

No kernel tree is touched. Exits 0.

### Build + boot (full pipeline)

Each config goes through `lib/build.sh` → `lib/vm.sh` → result recorded in
`build/<randkconfigconfig-CONFIG_NAME>-<arch>/`. Report written per-subsystem
run by `lib/report.sh` with label `kconfig-<subsystem>`.

Config naming inside the build dir:
`randkconfigconfig-PINCTRL_BM1880-arm64` — encodes both the profile and the
specific option under test.

### Architecture coverage

All three archs by default. Arch-specific drivers (e.g. `depends on ARCH_BCM`)
will either fail to build (expected — recorded as `BUILD_FAIL`) or be silently
skipped if `olddefconfig` drops the option when the arch doesn't match. Both
outcomes are valid and informative.

### Archive integration

`make config-archive` already scans all report dirs. No changes needed to
`scripts/config-archive.sh`. The new profile name `randkconfigconfig` is
automatically handled because the archive script reads the profile name from
the report dir name.

---

## Testing strategy

- **Dry-run** — `make kconfig-build SUBSYSTEM=pinctrl DRY_RUN=1` must print
  full list and correct total without touching the kernel tree
- **Single option** — `make kconfig-build SUBSYSTEM=pinctrl
  CONFIGS=randkconfigconfig-PINCTRL_BM1880 ARCHS=arm64` must reproduce the
  known BUILD_FAIL on v7.2-rc4 (before the fix is applied)
- **Full subsystem** — `make kconfig-build SUBSYSTEM=pinctrl` on a patched tree
  must show all options PASS or expected arch-mismatch BUILD_FAIL
- **Archive** — `make config-archive` after a run must index new entries under
  `randkconfigconfig`

---

## Testing commands

```sh
# 1. Dry run — print all builds without executing
make kconfig-build SUBSYSTEM=pinctrl DRY_RUN=1
# Expected: list of CONFIG_ × arch pairs, total count at end

# 2. Reproduce BM1880 build failure (on unpatched tree)
make kconfig-build SUBSYSTEM=pinctrl ARCHS=arm64 NO_FETCH=1
# Expected: CONFIG_PINCTRL_BM1880 arm64 → BUILD_FAIL

# 3. Verify fix (on patched tree)
make kconfig-build SUBSYSTEM=pinctrl ARCHS=arm64 NO_FETCH=1
# Expected: CONFIG_PINCTRL_BM1880 arm64 → PASS

# 4. Archive results
make config-archive
# Expected: new randkconfigconfig entries in configs/archive_*/index.txt
```
