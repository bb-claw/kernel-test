# report directory label naming — Plan

Branch: `feat/report-label-naming`
Start date: 2026-07-14

---

## Situation

Report directories used a datestamp-only format: `YYYY-MM-DD_HH-MM-SS_vX.Y-rcN`.
This made it impossible to distinguish mainline rc runs from stable release runs or
linux-next runs without opening the report content. The dmesg capture script
(`lib/dmesg.sh`) already used a label-first convention:
`dmesg-<label>-<version>-<datetime>-<config>.txt`. Aligning report dirs to that same
convention makes label and version immediately visible in a directory listing.

---

## Problems to Solve

1. **No label in dir name** — mainline, stable, longterm, and linux-next runs sort
   together and are visually indistinguishable
2. **make diff picks wrong pair** — the two most recent dirs might be from different
   labels (e.g. stable vs mainline), producing a misleading cross-label regression report
3. **No migration path** — existing report dirs won't match the new format without a
   rename script

---

## Goals

1. New report dirs named `${LABEL}-${MAJOR_MINOR}-${DATETIME}-${VERSION}`
   (e.g. `mainline-7.2-2026-07-11_10-10-43-v7.2-rc2`)
2. Label auto-derived from context: `STABLE_RELEASE` set → `stable`; `KERNEL_TREE`
   contains `linux-next` → `linux-next`; version matches `vX.Y.Z` (no rc) → `stable`;
   else `mainline`. User may override with `LABEL=longterm`
3. `make diff` (no OLD/NEW) auto-restricts to same label as the newest run
4. `scripts/migrate-reports.sh` renames existing dirs; dry-run default, `--apply` executes
5. Label appears in `summary.txt` preamble and HTML page header

---

## Scope

Files changed:
- `lib/report.sh` — add label derivation, change dir name formula, add label to preamble + HTML; filter prev-run diff to same label
- `lib/diff.sh` — add `_label` helper, filter same label in auto-detect mode, update `_ver` for new format
- `Makefile` — add `LABEL ?=` variable, export it, update help text
- `scripts/migrate-reports.sh` — new: rename existing dirs with version heuristic
- `docs/report-label-naming-plan.md` — this file
- `CLAUDE.md` — add `scripts/migrate-reports.sh` to Key files
- `memory/workflows.md` — add `LABEL` variable row, update diff/baseline sections
- `memory/project.md` — update report dir format documentation

No changes to: kernel build pipeline, VM tests, fetch/checkout, dmesg script.

---

## Non-goals

- Changing dmesg file naming (already uses label convention)
- Auto-detecting `longterm` (version format is identical to stable; user sets `LABEL=longterm`)
- Retroactive relabeling of report content — only dir names are renamed

---

## Design decisions

### New directory format

`mainline-7.2-2026-07-11_10-10-43-v7.2-rc2`

Label first — makes `ls reports/` immediately readable by label. Matches dmesg convention.
`MAJOR_MINOR` (e.g. `7.2`) extracted from KERNEL_VERSION by regex.

### Label auto-derivation precedence

1. `LABEL` env/Makefile variable — explicit user override
2. `STABLE_RELEASE` non-empty → `stable`
3. `KERNEL_TREE` contains `linux-next` → `linux-next`
4. KERNEL_VERSION matches `vX.Y.Z` (no `-rc`) → `stable`
5. Default → `mainline`

`longterm` is NOT auto-detected because its version format is identical to stable.
Set `LABEL=longterm` explicitly.

### diff.sh label restriction

When no OLD/NEW given: extract label from newest dir basename (first dash-segment),
filter all dirs to that label, then compare the two newest of that label.
Cross-label diff still possible via explicit `OLD=` / `NEW=`.

Old-format dirs (no label prefix) default to `mainline`.

### _ver compatibility in diff.sh

New format: regex on `YYYY-MM-DD_HH-MM-SS-<version>` — captures version after timestamp.
Old format: fallback to `${b##*_}` (last underscore-separated segment).

### Migration script

`scripts/migrate-reports.sh` — dry-run by default; `--apply` renames.

Label heuristic for old dirs:
- version ends in `-rcN` → `mainline`
- version matches `vX.Y.Z` (three-part, no rc) → `stable`
- otherwise → `mainline`

Auto-updates `baseline` symlink when its target is renamed.

---

## Testing strategy

- **New run dir**: `make report NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS=x86_64`;
  verify dir named `mainline-7.2-…`
- **LABEL override**: add `LABEL=longterm`; verify dir named `longterm-…`
- **diff auto-restrict**: mix mainline + stable dirs; verify `make diff` picks same-label pair
- **Migration dry-run**: `bash scripts/migrate-reports.sh`; old dirs listed, none renamed
- **Migration apply**: `bash scripts/migrate-reports.sh --apply`; dirs renamed, baseline updated
- **shellcheck**: all modified/new scripts pass shellcheck

---

## Testing commands

```sh
# 1. New dir format
make report NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS=x86_64
ls reports/
# Expected: mainline-7.2-YYYY-MM-DD_HH-MM-SS-v7.2-rc2/

# 2. LABEL override
make report NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS=x86_64 LABEL=longterm
ls reports/
# Expected: longterm-7.2-YYYY-MM-DD_HH-MM-SS-v7.2-rc2/

# 3. diff auto-restrict (only compares same-label dirs)
make diff

# 4. Migration dry-run
bash scripts/migrate-reports.sh
# Expected: WOULD RENAME: ... for each old-format dir, no changes

# 5. Migration apply
bash scripts/migrate-reports.sh --apply
# Expected: dirs renamed; baseline symlink updated if applicable

# 6. Shellcheck
shellcheck lib/report.sh lib/diff.sh scripts/migrate-reports.sh
# Expected: no output, exit 0
```
