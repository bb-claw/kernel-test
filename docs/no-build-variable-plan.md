# NO_BUILD variable — Plan

Branch: `feat/no-build-variable`
Start date: 2026-07-12

---

## Situation

The most common inner-loop workflow when iterating on test scripts is:
edit a test → rebuild initramfs → reboot VM → check results.
The kernel itself hasn't changed, so the build step is pure waste.

`make all NO_FETCH=1` currently forces the full build before every test run.
`localconfig` takes ~2.5 min per arch × 2 arches = ~5 min of unnecessary build time
on every iteration.  Skipping it would bring that cycle from ~7 min to ~1 min.

`NO_FETCH=1` already exists for skipping the fetch step; `NO_BUILD` follows the same
pattern.

---

## Problems to Solve

1. **No way to skip the build** — there is no flag to tell `make all` to skip the
   build step and use existing `build/<config>-<arch>/` artifacts.
2. **Chaining `make initramfs test report` is fragile** — if any step exits non-zero,
   the remaining steps are skipped.  `make all` guarantees the report is always written.

---

## Goals

1. `make all NO_FETCH=1 NO_BUILD=1 ...` skips the build step, uses existing
   `build.status` + `bzImage` artifacts, rebuilds the initramfs, runs tests, writes report.
2. `make build NO_BUILD=1` prints a clear skip message.
3. `NO_BUILD` appears in `make help` with its current value.

---

## Scope

Files changed:
- `Makefile` — add `NO_BUILD ?= 0`, export it, handle it in `build` target, document in help
- `CLAUDE.md` — add `NO_BUILD` to Conventions and to the "Running locally" example block
- `memory/workflows.md` — document the fast iteration workflow

No changes to: lib scripts, test scripts, hooks, config files.

---

## Non-goals

- `NO_INITRAMFS` — initramfs build is < 1 s; not worth a flag.
- `NO_TEST` — just run `make build initramfs report` in that case; chaining is fine
  when you don't need the report-on-failure guarantee.

---

## Design decisions

### Where to handle NO_BUILD

`NO_FETCH` is handled inside the `fetch` target, not in `all`.
`NO_BUILD` follows the same pattern: handled inside `build` with `ifeq`.
`make all` calls `$(MAKE) build` unconditionally; the `build` target decides what to do.
This keeps `all` simple and means `make build NO_BUILD=1` also works standalone.

### File prerequisites on `test`

`make test` has file prerequisites on `build/<c>-<a>/build.status`.
These trigger `_build_rule` (which calls `lib/build.sh`) only when the file is missing
or stale.  When `NO_BUILD=1` is set, the artifacts from the prior run are present and
up-to-date, so make never invokes the rule.  If artifacts are missing, make correctly
rebuilds them — the user set `NO_BUILD=1` incorrectly and make does the right thing.
No change needed to the file prerequisite rules.

---

## Testing strategy

- **Happy path** — run `make all NO_FETCH=1` once to build, then `make all NO_FETCH=1 NO_BUILD=1`;
  confirm build step is skipped and tests still pass.
- **Skip message** — `make build NO_BUILD=1` must print the skip message and exit 0.
- **Default unchanged** — `NO_BUILD=0` (default) must behave identically to today.

---

## Testing commands

```sh
# 1. Initial build (artifacts must exist before NO_BUILD=1 is useful)
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64
# Expected: build + test + report, OVERALL=PASS

# 2. Fast re-run with NO_BUILD=1
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS=x86_64
# Expected: "[build] Skipping (NO_BUILD=1)..." then initramfs + test + report, OVERALL=PASS
# Duration should be ~15s vs ~20s (initramfs + test only)

# 3. Standalone make build NO_BUILD=1
make build NO_BUILD=1 CONFIGS=tinyconfig ARCHS=x86_64
# Expected: "[build] Skipping (NO_BUILD=1)..." exit 0

# 4. Default still builds
make build NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64
# Expected: normal build output
```
