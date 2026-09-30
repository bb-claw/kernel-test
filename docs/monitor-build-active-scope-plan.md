# Monitor build_active scope fix — Plan

Branch: `fix/monitor-build-active-scope`
Start date: 2026-09-30

---

## Situation

`make monitor` showed builds as "active" that had already completed in a previous run. The BUILDS line reported active+done > total (e.g. 6+16=22 > 20), which made the dashboard misleading during `make full`.

---

## Problems to Solve

1. **Stale `.build-active` sentinels from prior runs** — `lib/monitor.sh` used an unconditional `find ... -name '.build-active'` covering all subdirs of `$BUILD_DIR`, including configs not in the current run (e.g. `allmodconfig`, `randconfig` which are build-only and never cleaned up between runs). `build_done` and `test_done` were already scoped to the current run's combos via `.run-plan` mtime; `build_active` and `test_active` were not.

---

## Goals

1. `build_active` shows only sentinels for combos in the current `.run-plan` configs×archs.
2. `test_active` shows only sentinels for combos in the current `.run-plan` boot_configs×archs.
3. Active+done ≤ total at all times during a run.

---

## Scope

Files/components changed:
- `lib/monitor.sh` — post-filter `build_active` and `test_active` arrays inside the existing `if [[ -n $_plan_configs ... ]]` scoping block, mirroring the already-correct `build_done`/`test_done` logic.

No changes to: `build.sh`, `vm.sh`, sentinel write/cleanup paths.

---

## Non-goals

- Cleaning up stale sentinels on disk — the filter is display-only; leftover files remain harmless.
- Build/test overlap (starting tests before all builds finish) — separate feature.

---

## Design decisions

### Post-filter in existing scoped block

Both `build_done` and `test_done` are already re-computed in a block gated on `$_plan_configs` and `$_plan_archs`. Adding the `build_active`/`test_active` filters there reuses the already-known plan combos and `.run-plan` mtime without restructuring the function. The alternative (adding `-newer "$BUILD_DIR/.run-plan"` to the `find`) would require moving `.run-plan` reading before the active scans, touching more code.

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
