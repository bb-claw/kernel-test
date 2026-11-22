# rand500config torture test exclusion — Plan

Branch: `fix/rand500config-torture-tests`
Start date: 2026-07-12

---

## Situation

`rand500config` builds on `tinyconfig` + 500 random `=y` options sampled from a
constrained `randconfig`. The constraint fragment (`configs/randconfig.config`) already
excludes sanitizers (KCOV, KASAN, etc.) and heavy subsystems (DRM, SOUND, etc.) to
prevent false build/boot failures. However, it did not exclude background torture tests,
which run as permanent kernel threads and flood the serial console continuously.

---

## Problems to Solve

1. **RCU torture test floods console** — `CONFIG_RCU_TORTURE_TEST=y` was randomly
   sampled, spawning kernel threads that emit hundreds of `rcu_torture_fwd_cb_hist`
   lines per second; `rand500config/i386` timed out after 30 s with 17/26 tests hung.

---

## Goals

1. `rand500config` never samples `RCU_TORTURE_TEST` or `LOCK_TORTURE_TEST`.
2. `rand500config/i386` completes all 26 tests within the 30 s timeout.

---

## Scope

Files/components changed:
- `configs/randconfig.config` — add `CONFIG_RCU_TORTURE_TEST=n` and `CONFIG_LOCK_TORTURE_TEST=n`

No changes to: test scripts, build.sh, vm.sh, Makefile, report.sh.

---

## Non-goals

- Excluding one-shot boot selftests (`STATIC_KEYS_SELFTEST`, `ATOMIC64_SELFTEST`, etc.) — they complete quickly and do not interfere.
- Fixing the root issue on all architectures (was i386-specific because x86_64 is faster and rand sampling is random).

---

## Design decisions

### Exclude in randconfig.config, not rand500config.config

`randconfig.config` constrains the source `randconfig` before sampling. Adding the
exclusions there means the options never enter the pool at all — cleaner than adding
them to the bootability fragment which runs after sampling.

---

## Testing strategy

- **rand500config/i386 boot** — rebuild with new constraint, verify 26/26 PASS within 30 s timeout.

---

## Testing commands

```sh
# 1. Rebuild rand500config/i386 with new constraint
make build NO_FETCH=1 CONFIGS=rand500config ARCHS=i386
# Expected: STATUS=PASS in build/rand500config-i386/build.status

# 2. Boot test
make test NO_FETCH=1 NO_BUILD=1 CONFIGS=rand500config ARCHS=i386 TIMEOUT=30
# Expected: PASS rand500config / i386 — boot OK, tests 26/26
```
