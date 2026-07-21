# kconfig-check — Design

Branch: `feat/kconfig-check`
Start date: 2026-07-20

---

## Situation

Kconfig dependency bugs (missing `select`) are found by accident via randconfig
build failures. There is no proactive tool to scan a kernel subsystem and flag
drivers that use a `#ifdef CONFIG_X`-guarded API or `IS_ENABLED(CONFIG_X)` without
declaring `select CONFIG_X` in their Kconfig entry. The BM1880 pinctrl bug
(`select GENERIC_PINCONF` missing) sat unfixed since 2019 and was only found by
kernel-test's rand500config arm64 sweep on v7.2-rc4.

---

## Problems to Solve

1. **Reactive discovery** — Kconfig inconsistencies are found only when a random
   config happens to hit the missing symbol. Most never surface.
2. **No subsystem-level sweep** — There is no way to ask "does the pinctrl
   subsystem have any missing selects?" without running thousands of random builds.
3. **False confidence** — A clean rand500config run does not mean a subsystem is
   consistent; it only means the random sample didn't hit the gap.

---

## Goals

1. `make kconfig-check SUBSYSTEM=<name>` runs in seconds and reports candidate
   missing-select bugs for the named subsystem against KERNEL_TREE.
2. Script is runnable standalone from KERNEL_TREE without kernel-test.
3. Optional `VERIFY=1` flag triggers a build of each flagged driver to confirm
   the candidate is a real build failure (not a false positive).
4. Optional `ARCHS=<arch>` selects the build architecture for VERIFY=1.
5. Optional `DRIVER=<stem>` restricts the scan to a single driver C file.
6. Optional `PASS2=1` enables the IS_ENABLED() pass (off by default; high
   false-positive rate — IS_ENABLED is intentionally safe without select).
7. Optional `SKIP_CFGS=CONFIG_X,CONFIG_Y` skips symbols as missing-select
   candidates (e.g. `CONFIG_DEBUG_FS` — intentionally optional in most drivers).
8. Optional `GATE_CFGS=CONFIG_X` enables symbols in `verify_build` so drivers
   inside `if SYMBOL ... endif` blocks appear in `.config` after `olddefconfig`
   (e.g. `CONFIG_GPIOLIB` — the gpio subsystem gate, not auto-detected because
   `config_sym("gpio")` = `GPIO` ≠ `GPIOLIB`).
9. Output is human-readable and grep-friendly.

---

## Scope

Files/components changed:
- `scripts/kconfig-check.sh` — new standalone analysis script
- `Makefile` — new `kconfig-check` target passing KERNEL_TREE, SUBSYSTEM, ARCH, DRIVER

No changes to: `lib/`, `configs/`, `tests/`, existing make targets.

---

## Non-goals

- Whole-tree scan (start with SUBSYSTEM= scoped; can be added later)
- Automatic patch generation
- Integration with config archive (that is approach 2 / feat/kconfig-build)
- Checking `depends on` consistency (only `select` gaps for now)

---

## Design decisions

### Subsystem path derivation

`SUBSYSTEM=pinctrl` automatically maps to:
- Headers: `$KERNEL_TREE/include/linux/pinctrl/*.h`
- Drivers: `$KERNEL_TREE/drivers/pinctrl/`
- Kconfig: `$KERNEL_TREE/drivers/pinctrl/Kconfig`

No hardcoded table. Derived from standard kernel layout.

### What to detect

Two patterns that indicate a driver uses a conditionally-compiled symbol:

1. **`#ifdef CONFIG_X` in a subsystem header** — guards a struct field or function
   declaration. Drivers using that field/function need `select CONFIG_X`.
   **Always active (Pass 1).** High signal.

2. **`IS_ENABLED(CONFIG_X)` in a driver C file** — driver conditionally calls code
   based on a symbol. `IS_ENABLED` is intentionally safe without `select` (expands
   to 0 when config is absent), so this pass has a high false-positive rate.
   **Opt-in via `PASS2=1`.**

The subsystem gate symbol (`CONFIG_<SUBSYSTEM>`, e.g. `CONFIG_PINCTRL`) is skipped
in both passes. All drivers inside `if SUBSYSTEM … endif` blocks implicitly depend on
it — flagging it would produce a false positive for every driver in the subsystem.

### Analysis algorithm

```
for each CONFIG_X guarding code in subsystem headers:
    extract the guarded symbol names (struct fields, function names)
    for each driver .c file in drivers/<subsystem>/:
        if DRIVER= is set, skip files that don't match
        if driver uses any guarded symbol:
            find driver's config entry in Kconfig (config PINCTRL_<NAME>)
            if entry does not select CONFIG_X:
                report candidate: driver, missing select, evidence line
for each IS_ENABLED(CONFIG_X) in drivers/<subsystem>/*.c:
    find driver's Kconfig entry
    if entry does not select CONFIG_X:
        report candidate
```

### False positives

A symbol may be selected transitively (another selected symbol selects it).
Static analysis cannot resolve transitive selects without a full Kconfig solver.
`VERIFY=1` eliminates false positives by building the flagged driver object.

A second class of false positive: a driver that is inside `if SYMBOL … endif`
can never be enabled without SYMBOL=y, so a missing `select SYMBOL` is
unreachable. The VERIFY=1 guard detects this: if the driver symbol is absent
from `.config` after `olddefconfig`, the candidate is reported as FALSE_POSITIVE
with the `depends on` line printed so the user can see why.

### Output format

```
[CANDIDATE] drivers/pinctrl/pinctrl-bm1880.c
  Kconfig entry : config PINCTRL_BM1880
  Missing select: CONFIG_GENERIC_PINCONF
  Evidence      : pinctrl-bm1880.c:1288: .is_generic = true,
  Note          : field guarded by #ifdef CONFIG_GENERIC_PINCONF in include/linux/pinctrl/

  -> [VERIFIED — build fails without select]
     log: build/kconfig-check-arm64/PINCTRL_BM1880/GENERIC_PINCONF/build.log
     reproducer: build/kconfig-check-arm64/PINCTRL_BM1880/GENERIC_PINCONF/reproducer.sh
```

One block per candidate. Machine-greppable: result lines start with
`-> [VERIFIED`, `-> [FALSE_POSITIVE`, or no result line when VERIFY=0.

### VERIFY=1 mode

For each candidate, `verify_build()`:

1. Runs `make ARCH=<arch> tinyconfig` in a temp out-of-tree build dir.
2. Enables, via `scripts/config`, only the symbols actually required:
   - `CONFIG_OF` — if `depends on` mentions `OF`
   - `CONFIG_COMPILE_TEST` — if `depends on` mentions `COMPILE_TEST`
   - `CONFIG_<SUBSYSTEM>` — the subsystem gate (e.g. `CONFIG_PINCTRL`)
   - `CONFIG_<DRIVER>` — the driver under test
3. Runs `olddefconfig` to resolve the dependency graph.
4. Checks `CONFIG_<DRIVER>=y` in the resulting `.config`. If absent, the driver
   has an unsatisfied dependency that our enablers didn't cover — reported as
   FALSE_POSITIVE with the `depends on` line from the Kconfig entry.
5. Builds the driver object: `make ARCH=<arch> drivers/<subsystem>/<file>.o`
6. If build fails → VERIFIED (real bug); if build passes → FALSE_POSITIVE
   (transitive select already resolved it).

Logs saved to `build/kconfig-check-<ARCH>/<SYM>/<CFG>/`:
- `tinyconfig.log` — config setup output (check here if tinyconfig fails)
- `olddefconfig.log` — dependency resolution output
- `.config` — the exact config used for the build
- `build.log` — compiler output (VERIFIED candidates only)
- `reproducer.sh` — self-contained shell script to recreate the failure;
  includes `set -x`, only the dep enables actually needed, and grep checks
  to confirm the driver is =y and the missing dep is absent after olddefconfig

**Kernel source tree must be clean** for out-of-tree VERIFY builds. If
`tinyconfig` fails with "source tree is not clean", run:
```sh
make -C "$KERNEL_TREE" mrproper
```

### Architecture and cross-compile

`ARCHS=arm64` (or any single arch from the standard ARCHS list) selects the
build architecture. The Makefile passes `ARCH=$(firstword $(ARCHS))` to the
script. CROSS_COMPILE is derived automatically:
- `arm64` → `aarch64-linux-gnu-`
- `x86_64`, `i386` → (empty)

Default is `x86_64` when ARCHS is not specified.

---

## Known limitations

- **Multi-line `depends on`**: if the continuation line holds `OF` or
  `COMPILE_TEST` (e.g. `depends on \ \n    OF && ...`), it won't be detected by
  the single-line grep. The false-positive guard catches it — the driver is
  absent from `.config` and the `depends on` line is printed.
- **Nested `if` blocks beyond the subsystem gate**: only the top-level subsystem
  gate symbol is enabled. Drivers inside a nested `if ACPI` block would be
  dropped. Same false-positive guard applies.
- **IS_ENABLED false positives (Pass 2)**: `IS_ENABLED(CONFIG_MACH_X)` used for
  SoC detection at compile time is not a missing-select bug. VERIFY=1 will mark
  these FALSE_POSITIVE (builds OK). Pass 2 is disabled by default for this reason;
  enable with `PASS2=1` when doing exploratory scanning.
- **Scan scope**: only `drivers/<subsystem>/*.c` (top-level files). Subdirectories
  are not scanned.

---

## Testing commands

```sh
# Static analysis only (no build) — Pass 1 only
make kconfig-check SUBSYSTEM=pinctrl

# Static analysis including IS_ENABLED pass
make kconfig-check SUBSYSTEM=pinctrl PASS2=1

# Single driver, arm64, with verification
make kconfig-check SUBSYSTEM=pinctrl DRIVER=pinctrl-bm1880 ARCHS=arm64 VERIFY=1

# Full subsystem sweep with verification, arm64
make kconfig-check SUBSYSTEM=pinctrl ARCHS=arm64 VERIFY=1

# Full sweep including IS_ENABLED candidates
make kconfig-check SUBSYSTEM=pinctrl ARCHS=arm64 VERIFY=1 PASS2=1

# gpio subsystem: GPIOLIB is the gate but not auto-detected (GPIO≠GPIOLIB);
# SKIP_CFGS suppresses it as a candidate; GATE_CFGS enables it in verify_build
# so drivers inside 'if GPIOLIB endif' appear in .config after olddefconfig
make kconfig-check SUBSYSTEM=gpio ARCHS=arm64 VERIFY=1 \
    SKIP_CFGS=CONFIG_GPIOLIB,CONFIG_DEBUG_FS,CONFIG_PM \
    GATE_CFGS=CONFIG_GPIOLIB

# Standalone from kernel tree
cd ~/git/linux
~/git/kernel-test/scripts/kconfig-check.sh pinctrl
```
