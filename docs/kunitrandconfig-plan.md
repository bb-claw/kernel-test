# kunitrandconfig — Plan

Branch: `feat/kunitrandconfig`
Start date: 2026-07-14

---

## Situation

`kunitconfig` tests a fixed set of KUnit test suites (9 modules, all in lib/ and mm/).
The kernel ships ~100 KUnit test modules covering many subsystems (IRQ, timer, CRC,
binfmt, DM, regmap, unicode, etc.).  Testing a random selection of those modules on
each run would increase KUnit coverage substantially without needing to maintain a
curated list of every available module.

The v7.2-rc3 rand500config failure on i386 also revealed that sampling KUnit options
into a tinyconfig base causes `kunit_try_catch` to fail to intercept deliberate test
faults (PREEMPT_LAZY + tinyconfig = real Oops).  The fix: exclude CONFIG_KUNIT from
the rand500config pool AND add a dedicated profile on defconfig base.

---

## Problems to Solve

1. **rand500config KUnit Oops** — KUnit on tinyconfig base with PREEMPT_LAZY causes
   real Oops from the `lib/kunit/kunit-test.c:725` intentional NULL dereference.
2. **kunitconfig coverage is fixed** — the 9 hand-picked modules never change; the
   ~90 other KUnit modules in the kernel go untested.

---

## Goals

1. `CONFIG_KUNIT=n` in `configs/randconfig.config` prevents rand500config from sampling KUnit.
2. New `kunitrandconfig` profile: every run tests a different random subset of the KUnit
   modules available on defconfig base.
3. Only valid, buildable KUnit modules are included — `olddefconfig` is the gatekeeper.

---

## Scope

Files/components changed:
- `configs/randconfig.config` — add `CONFIG_KUNIT=n` exclusion
- `configs/kunitrandconfig.config` — new fragment: CONFIG_KUNIT=y + core suites baseline
- `lib/build.sh` — add `kunitrandconfig` elif case
- `Makefile` — add `kunitrandconfig` to default `CONFIGS`
- `memory/config-profiles.md`, `memory/project.md`, `CLAUDE.md` — documentation

No changes to: vm.sh, report.sh, diff.sh, test scripts, initramfs.sh.

---

## Non-goals

- Randomising non-KUnit options in kunitrandconfig (rand500config already covers that).
- Curating a specific list of KUnit modules to include/exclude.
- Fixing the PREEMPT_LAZY + i386 + kunit_try_catch kernel bug (separate issue).

---

## Design decisions

### Enumerate from randconfig, not from Kconfig introspection

`make randconfig` in a temp dir sets all options randomly, including every KUnit test
module the kernel knows about for this arch.  Grepping `CONFIG_*KUNIT*=y` from the
result gives the complete available set without needing to parse Kconfig files.

Alternative: `make listnewconfig` or direct Kconfig parsing — more complex, no benefit.

### defconfig base, not tinyconfig

The v7.2-rc3 Oops proved tinyconfig is insufficient for KUnit infrastructure (specifically
`kunit_try_catch` exception recovery).  defconfig provides all required infrastructure.

### Fragment re-enforces core suites

The kunitrandconfig.config fragment lists the same 9 core modules as kunitconfig.
This guarantees that every kunitrandconfig run includes the known-good baseline, even
if those options weren't in the randconfig enumeration for this particular run.

### olddefconfig as the validity gate

Rather than maintaining a blocklist of broken modules, let the kernel's own dependency
resolver drop anything that can't be satisfied.  A module that compiles but crashes at
runtime on defconfig base would indicate a real kernel bug — worth catching.

### Save kunitrand-sampled.config

Analogous to rand-sampled.config for rand500config.  Lets you see which modules were
tried, independent of what olddefconfig kept.

---

## Testing strategy

- **Build** — `make build NO_FETCH=1 CONFIGS=kunitrandconfig ARCHS=x86_64`; verify
  `build.status STATUS=PASS` and `kunitrand-sampled.config` is populated.
- **Boot** — `make test NO_FETCH=1 NO_BUILD=1 CONFIGS=kunitrandconfig ARCHS=x86_64`;
  verify `kunit:N/N` in output (N should be ≥ 259 from kunitconfig, more if extra
  modules were added).
- **rand500config regression** — verify `CONFIG_KUNIT is not set` in a fresh
  rand500config build with the new constraint.

---

## Testing commands

```sh
# 1. Build kunitrandconfig x86_64
make build NO_FETCH=1 CONFIGS=kunitrandconfig ARCHS=x86_64
# Expected: STATUS=PASS, kunitrand-sampled.config lists KUNIT options tried

# 2. Boot test
make test NO_FETCH=1 NO_BUILD=1 CONFIGS=kunitrandconfig ARCHS=x86_64
# Expected: PASS kunitrandconfig / x86_64 — boot OK, kunit:N/N (N ≥ kunitconfig baseline)

# 3. Confirm rand500config no longer samples KUNIT
make build NO_FETCH=1 CONFIGS=rand500config ARCHS=x86_64
grep KUNIT build/rand500config-x86_64/.config
# Expected: # CONFIG_KUNIT is not set
```
