# kconfig-check — Plan

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
3. Optional `VERIFY=1` flag triggers a build of each flagged config to confirm
   the candidate is a real build failure (not a false positive).
4. Output is human-readable and grep-friendly.

---

## Scope

Files/components changed:
- `scripts/kconfig-check.sh` — new standalone analysis script
- `Makefile` — new `kconfig-check` target passing KERNEL_TREE and SUBSYSTEM
- `CLAUDE.md` — add `kconfig-check` to Key files table

No changes to: `lib/`, `configs/`, `tests/`, existing make targets.

---

## Non-goals

- Whole-tree scan (start with SUBSYSTEM= scoped; SUBSYSTEM=all can be added later)
- Automatic patch generation
- Integration with config archive (that is approach 1 / feat/kconfig-build)
- Checking `depends on` consistency (only `select` gaps for now)

---

## Design decisions

### Subsystem path derivation

`SUBSYSTEM=pinctrl` automatically maps to:
- Headers: `$KERNEL_TREE/include/linux/pinctrl/*.h`
- Drivers: `$KERNEL_TREE/drivers/pinctrl/`
- Kconfig: `$KERNEL_TREE/drivers/pinctrl/Kconfig`

No hardcoded table. Derived from standard kernel layout. Works for the majority
of subsystems. Edge cases (e.g. `gpio` headers under `include/linux/gpio/` but
drivers under `drivers/gpio/`) are handled naturally by the same convention.

### What to detect

Two patterns that indicate a driver uses a conditionally-compiled symbol:

1. **`#ifdef CONFIG_X` in a subsystem header** — guards a struct field or function
   declaration. Drivers using that field/function need `select CONFIG_X`.

2. **`IS_ENABLED(CONFIG_X)` in a driver C file** — driver conditionally calls code
   based on a symbol. If the driver never selects it, the call may be dead code or
   may cause a build error depending on the guard in the called function.

### Analysis algorithm

```
for each CONFIG_X guarding code in subsystem headers:
    extract the guarded symbol names (struct fields, function names)
    for each driver .c file in drivers/<subsystem>/:
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
`VERIFY=1` eliminates false positives by building the flagged config.
Without `VERIFY=1`, candidates are labelled "possible missing select — verify
with VERIFY=1".

### Output format

```
[CANDIDATE] drivers/pinctrl/pinctrl-bm1880.c
  Kconfig entry : config PINCTRL_BM1880
  Missing select: CONFIG_GENERIC_PINCONF
  Evidence      : pinctrl-bm1880.c:1288: .is_generic = true
                  (guarded by #ifdef CONFIG_GENERIC_PINCONF in pinconf.h)
```

One block per candidate. Machine-greppable: lines start with `[CANDIDATE]`,
`[VERIFIED]`, or `[FALSE_POSITIVE]` when VERIFY=1 is used.

### Standalone usage (from KERNEL_TREE)

```sh
cd ~/git/linux
~/git/kernel-test/scripts/kconfig-check.sh pinctrl
```

Script auto-detects it is run from a kernel tree (checks for `Kconfig` at root).

### VERIFY=1 mode

When `VERIFY=1`, for each candidate:
- Build `tinyconfig` + enable the driver's config option + `olddefconfig`
- Build the driver object: `make ARCH=x86_64 drivers/<subsystem>/<file>.o`
- If build fails → `[VERIFIED]` real bug
- If build passes → `[FALSE_POSITIVE]` (transitive select resolved it)

Uses x86_64 by default for speed. Arm64 cross-compile only if driver is
arm64-specific (`depends on ARM64` in Kconfig).

---

## Testing strategy

- **Correctness** — run against pinctrl subsystem on v7.2-rc4; must flag
  `PINCTRL_BM1880` / `CONFIG_GENERIC_PINCONF` as a candidate
- **False positive rate** — compare candidates against known-good drivers that
  already have correct selects; expect zero false positives for those
- **VERIFY=1** — confirmed candidate must show build failure; known-good must
  not flag
- **Standalone** — run directly from `~/git/linux` without kernel-test

---

## Testing commands

```sh
# 1. Static analysis — must flag BM1880
make kconfig-check SUBSYSTEM=pinctrl
# Expected: [CANDIDATE] PINCTRL_BM1880 missing CONFIG_GENERIC_PINCONF

# 2. Verify mode — must confirm as real build failure
make kconfig-check SUBSYSTEM=pinctrl VERIFY=1
# Expected: [VERIFIED] PINCTRL_BM1880 — build failed without CONFIG_GENERIC_PINCONF

# 3. Standalone from kernel tree
cd ~/git/linux
~/git/kernel-test/scripts/kconfig-check.sh pinctrl
# Expected: same output as above

# 4. Clean subsystem — expect no candidates (or only known false positives)
make kconfig-check SUBSYSTEM=i2c
# Expected: 0 candidates or all FALSE_POSITIVE after VERIFY=1
```
