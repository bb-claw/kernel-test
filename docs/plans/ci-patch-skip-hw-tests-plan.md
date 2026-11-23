# ci-patch-skip-hw-tests: plan

**Branch**: `fix/ci-patch-skip-hw-tests`
**Status**: in-progress

---

## Situation

`ci-patch` (SH-014 tier 2: post-merge smoke) runs `make ci-test` on
ubuntu-latest with only `actions/checkout` — no apt-get install, no
`make programs`, no global git identity. ci-branch (SH-035) does all
three before ci-test, so the same 50-script suite passes there but
fails as 5/50 on ci-patch. ci-nightly (fixed yesterday to run
`lint ci-test` instead of `smoke`) will hit the same failures on its
next scheduled run.

---

## Problems to solve

1. **test-board-serial.sh** — `finish()` returns a status but doesn't
   exit, so after the socat-missing skip the downstream sections
   (`run_board_replay`, bash fallback, missing-tty) still ran and tripped
   `set -e` on "socat: command not found".
2. **test-ccache-share.sh** — `make ccache-status` / `ccache-init` shell
   out to the `ccache` binary; absent on a bare ubuntu-latest runner.
3. **test-init-data-repo.sh** — `scripts/init-data-repo.sh` runs
   `git init && git commit`, which fails without a global
   `user.name`/`user.email`. ci-branch configures these;
   `actions/checkout` on ci-patch does not.
4. **test-ns-time-fix.sh** — three integration sections invoke
   `tests/ns/bin/x86_64/ns-time-gcc`, built by `make programs`. ci-patch
   intentionally skips `make programs` (that's the tier 1 job).
5. **test-report.sh** — asserts `Tested-by:` line in the generated
   `summary.txt`; `lib/report.sh` derives it from `git config
   user.name/user.email` and omits the line when either is empty.

---

## Goals

1. All 50 ci-test scripts report `passed` (possibly with internal `skip`
   notes) on a fresh ubuntu-latest runner with no preinstalled deps.
2. The same 50 scripts continue to pass end-to-end on a developer
   machine (`make bootstrap` installed socat/ccache/cross-gcc etc.).
3. No test is deleted, renamed, or moved to a separate target — the
   coverage surface is unchanged.

---

## Scope

Files changed:

- `tests/ci/test-board-serial.sh` — add `exit $?` after `finish` in the
  socat-missing branch.
- `tests/ci/test-ccache-share.sh` — add early `command -v ccache` skip
  (mirrors `test-build-sentinel.sh`).
- `tests/ci/lib.sh` — `setup_git_stub` now exports `GIT_AUTHOR_*` /
  `GIT_COMMITTER_*` env vars so sub-`git commit` calls succeed without
  touching the runner's global config.
- `tests/ci/test-ns-time-fix.sh` — three integration sections report
  `pass` with a `skip` note when `ns-time-gcc` is absent instead of
  `fail`.
- `tests/ci/test-report.sh` — gate the `Tested-by:` assertion on
  harness git identity being set.
- `VERSION` — 0.1.2 → 0.1.3.

No changes to: `Makefile` (ci-patch body stays `ci-test`), any workflow
yaml, any test coverage-map.

---

## Non-goals

- Making ci-patch install socat/ccache/cross-gcc or run `make programs`.
  That is ci-branch's job by design (build-once-promote, SH-014); ci-patch
  stays a fast post-merge smoke.
- Adding a global `CI_HW_DEPENDENT=` exclusion variable or a
  `.ci-exclude` file. The in-script skip pattern already exists
  (`test-build-sentinel.sh`), is grep-friendly, and keeps each test's
  prerequisites alongside its assertions.

---

## Design decisions

### Why in-script skips, not a central exclude list

The repo already uses `command -v <tool> || { skip; exit 0; }` inside
`test-build-sentinel.sh`. Extending that pattern to the five new cases
keeps all dependency knowledge in one place per test, preserves local
runs (full coverage with `make bootstrap` deps installed), and avoids a
new mechanism nobody has to maintain. Alternatives rejected:

- **Separate `make ci-test-hw` target** — duplicates the runner, hides
  that the tests are still valid on a fully provisioned machine.
- **Install deps in ci-patch workflow** — contradicts build-once-promote
  (SH-014); ci-patch must stay a fast smoke.

---

## Breaking changes

- [x] None — strictly additive; test counts go up (new skip-`pass` lines)
      but every previously-green assertion still runs.

---

## Rollout

- [ ] `README.md` updated — N/A (no public contract change)
- [ ] `memory/` files — N/A (internal test harness)
- [ ] `docs/CAPABILITIES.md` — N/A (no new CAPs)

---

## Testing commands

```sh
make ci-test
# Expected: [ci-test] 50 passed, 0 failed

make lint
# Expected: [lint] all checks passed
```

Simulate CI runner (no socat/ccache/git identity/ns-time-gcc):

```sh
# Verified before commit: 5 previously-failing tests now report pass+skip.
```
