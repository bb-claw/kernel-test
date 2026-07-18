# feat/archive-index-v2 — Plan

Branch: `feat/archive-index-v2`
Start date: 2026-07-18

---

## Problem

The current `index.txt` and `index.html` in `configs/archive_passed/` and
`configs/archive_failed/` have two shortcomings:

1. **One row per SHA, no run history** — the index doesn't show which report
   directory produced a given config, and a SHA that was tested across multiple
   kernel versions has only one row (the most recently found run).

2. **No cross-result indicator** — a SHA that appears in both `archive_passed/`
   and `archive_failed/` (graduated or regressed) is not flagged anywhere,
   making it hard to spot regressions or improvements at a glance.

---

## Proposed Solution

Regenerate `index.txt` and `index.html` with the following changes:

### Column layout — passed

| Column | txt width | Notes |
|---|---|---|
| Config | dynamic | e.g. `tinyconfig` |
| Arch | 6 | `x86_64`, `i386`, `arm64` |
| Version | 12 | e.g. `v7.2-rc3` |
| Runs | 4 | total run count for this SHA |
| Report dir | 52 (fixed) | full dir name; badge `[✗ also failed]` appended when cross-result |
| Files | ~40 | `config` link + `build.log` link (conditional) + `dmesg` link (conditional) |
| SHA256 | 64 | full hash |

### Column layout — failed

Same as passed plus a **Failure reason** column (e.g. `BUILD_FAIL`,
`BOOT_FAIL-kernel-panic`) inserted after Version.

### Row model — one row per run

Each report directory that used a given SHA gets its own row. Config, arch,
version, and SHA are repeated on every row. This keeps diffs clean (new runs
add rows; existing rows never change) and makes every row self-contained.

### Cross-result badge

- `[✓ also passed]` — on a row in `archive_failed/` whose SHA also exists in `archive_passed/`
- `[✗ also failed]` — on a row in `archive_passed/` whose SHA also exists in `archive_failed/`
- Appended to the Report dir field in `index.txt`
- In `index.html`: a separate **Cross-result** column with a clickable badge
  linking to `../archive_failed/index.html#<sha>` (or `../archive_passed/…`)

### Sort order

Config → Arch → Version (ascending). Within the same triple, rows for the
same SHA are adjacent (same SHA, different run dirs).

### HTML anchors

The first row for each SHA carries `id="<sha256>"` on the `<tr>` element,
enabling cross-index badge links to jump directly to the conflict row.

### Header section

Both index files open with a one-line preamble:
```
Passed configs archive — 171 entries — generated 2026-07-18T14:10:00Z
```
(or "Failed configs archive" for the other dir). The generated timestamp means
the file always changes on every `make config-archive` run; this is acceptable
because the indices are gitignored during active development and committed only
when the archive itself changes.

### Report dir link target

HTML: `../../reports/<dir>/` (directory listing).
txt: plain name with optional badge appended.

---

## Data model changes in `generate_index()`

### Current

- `sha256 → single dmesg path` (first match in reports/)
- One row per archive file (= one row per unique SHA)

### New

- `sha256 → array of report_dirs` (all matches, newest first)
- `sha256 → run_count` (length of that array)
- Cross-result sets: `passed_shas` and `failed_shas` built before rendering
- Sorted row list: `(config, arch, version, sha, report_dir)` tuples,
  sorted by config+arch+version, then by report_dir descending

### Scanning change

`generate_index()` must scan `reports/*/summary.txt` to build the
`sha256 → [report_dirs]` mapping (the same way the current dmesg lookup
works, but collecting all matches instead of stopping at the first).

---

## Files changed

| File | Change |
|---|---|
| `scripts/config-archive.sh` | Rewrite `generate_index()` — new data model, new column layout, row-per-run, cross-result, anchors, header |
| `configs/archive_passed/index.txt` | Regenerated |
| `configs/archive_passed/index.html` | Regenerated |
| `configs/archive_failed/index.txt` | Regenerated |
| `configs/archive_failed/index.html` | Regenerated |
| `CLAUDE.md` | Update index format description |
| `memory/workflows.md` | Update index format description |

---

## Decisions

1. **One row per run** — diff-friendly and self-contained; SHA + config + arch
   repeated on each row; run count column gives totals context
2. **Fixed 52-char report dir column in txt** — stable column widths despite
   accumulating runs; long names silently truncated (all current names fit in 52)
3. **Full SHA in txt** — 64 chars; makes the table wide but unambiguous; cross-
   column alignment uses fixed widths for all other columns to compensate
4. **Badge appended to report dir in txt** — keeps column count constant;
   `[✗ also failed]` / `[✓ also passed]` at the right edge of that field
5. **`<tr id="<sha256>">` on first row per SHA** — valid HTML (unique id);
   subsequent rows for the same SHA omit the id; cross-index badge links jump
   to the anchor
6. **Title + count + timestamp in header** — informative; timestamp changes on
   every regeneration but that is acceptable (same as existing index behaviour)
7. **Keep both report-dir and dmesg columns** — report dir always shown;
   `build-<config>-<arch>.log` link added when present in the local `reports/` dir;
   `dmesg-<config>-<arch>.txt` link added likewise (dmesg absent for build-only configs)
