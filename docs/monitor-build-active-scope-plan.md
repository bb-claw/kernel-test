# Monitor build_active scope fix — Plan

Branch: `fix/monitor-build-active-scope`
Start date: 2026-09-30

---

## Situation

`make monitor` showed builds as "active" that had already completed in a previous run. The BUILDS line reported active+done > total (e.g. 6+16=22 > 20), which made the dashboard misleading during `make full`.

---

## Problems to Solve

1. **Stale `.build-active` sentinels from prior runs** — `lib/monitor.sh` used an unconditional `find ... -name '.build-active'` covering all subdirs of `$BUILD_DIR`, including configs not in the current run (e.g. `allmodconfig`, `randconfig` which are build-only and never cleaned up between runs). `build_done` and `test_done` were already scoped to the current run's combos via `.run-plan` mtime; `build_active` and `test_active` were not.

2. **`build.sh` EXIT trap cleared by `trap - EXIT`** — rand500config and kunitrandconfig sections used `trap 'rm -rf "$RAND_TMP"' EXIT` (overwriting the main trap) then `trap - EXIT` (clearing it entirely). Any build that reached those sections would leave `.build-active` on disk permanently — even on normal completion — and never write `LINKER=` to `build.status`.

3. **`_plan_total` grep aborts on missing `.run-plan`** — `_plan_total=$(grep ... | cut ...)` with `set -o pipefail`: when `.run-plan` doesn't exist, `grep` exits 2, the pipeline exits 2, and `set -e` fires before the sentinel is written. Silent in normal pipeline (`.run-plan` always exists) but fatal in standalone invocations and CI tests.

---

## Goals

1. `build_active` shows only sentinels for combos in the current `.run-plan` configs×archs.
2. `test_active` shows only sentinels for combos in the current `.run-plan` boot_configs×archs.
3. Active+done ≤ total at all times during a run.
4. `.build-active` is always removed when `build.sh` exits, regardless of which config section ran.
5. `LINKER=` is always written to `build.status` on exit (via `_cleanup_sentinel`).
6. `build.sh` does not abort when `.run-plan` is absent (standalone invocation / CI).

---

## Scope

Files/components changed:
- `lib/monitor.sh` — post-filter `build_active`/`test_active` arrays to current-run combos; add `-newer "$BUILD_DIR/.run-plan"` to all three sentinel `find` calls.
- `lib/build.sh` — extract `_cleanup_sentinel()` function; replace `trap 'rm -rf "$RAND_TMP"' EXIT` + `trap - EXIT` with compound trap + base restore in rand500config and kunitrandconfig sections; add `|| true` to `_plan_total` grep pipeline.
- `tests/ci/test-monitor.sh` — M3–M8 scoping tests.
- `tests/ci/test-build-sentinel.sh` — new file; I4–I7 sentinel lifecycle tests.
- `tests/ci/coverage-map.md` — new entries.
- `memory/code-quality.md` — new bash lib pitfall entry.

No changes to: `vm.sh`, `.vm-active` write/cleanup paths, initramfs.

---

## Non-goals

- Cleaning up stale sentinels on disk — the filter is display-only; leftover files remain harmless.
- Build/test overlap (starting tests before all builds finish) — separate feature.

---

## Design decisions

### Two-layer filtering in monitor.sh

Both guards are applied together and are complementary:
1. **`-newer .run-plan`** on `find`: excludes any sentinel whose mtime predates the current run — handles stale sentinels for the same combo left by a hard-killed prior run.
2. **Combo post-filter**: excludes sentinels for configs not in the current plan — handles the common case where a prior run included `allmodconfig`/`randconfig` which aren't in `make full`.

Neither alone covers both cases. The post-filter is applied inside the already-existing `if [[ -n $_plan_configs ... ]]` scoped block, reusing plan variables without restructuring the function.

### `_cleanup_sentinel` function in build.sh

Extracting the cleanup to a named function (`_cleanup_sentinel`) avoids duplicating the `rm -f`/`printf` string in the compound trap (`trap '{ rm -rf "$RAND_TMP"; _cleanup_sentinel; }'`) and the two restore points (`trap '_cleanup_sentinel' EXIT`). Any future change to cleanup behaviour has one edit point.

---

## Testing strategy

- **Visual** — run `make monitor` during a `make all` run; confirm active count never exceeds total.
- **Lint** — `shellcheck` clean; no new warnings.
- **No automated test** — `monitor.sh` is an interactive dashboard; its output is not captured by `tests/ci/`.

---

## Testing commands

```sh
make lint
# Expected: all checks passed

shellcheck --severity=warning lib/monitor.sh
# Expected: no output (clean)
```
