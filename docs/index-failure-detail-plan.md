# feat/index-failure-detail — Plan

Branch: `feat/index-failure-detail`
Start date: 2026-07-19

---

## Problem

`configs/archive_failed/index.txt` and `index.html` show a `FAILURE REASON`
column (e.g. `BUILD_FAIL`, `BOOT_FAIL-kernel-panic`, `TEST_FAIL-3-of-26`) but
give no indication of *why* a build failed or *which* tests failed.  To
investigate a failure the user must manually open the linked report dir.

---

## Solution

Extend `generate_index()` in `scripts/config-archive.sh` to read the report
dir files for each failed entry and emit a one-line detail:

- **index.txt** — indented `    -> <detail>` line immediately below the row
- **index.html** — `title="<detail>"` tooltip on the Failure reason `<td>`;
  `cursor:help` CSS makes the tooltip discoverable on hover

Detail is only emitted when the report dir is reachable.  When reports/ is
absent (another machine, no local runs), entries silently have no detail — the
existing FAILURE REASON column is unchanged.

---

## Detail sources per failure type

| Failure type | Source file | Extraction |
|---|---|---|
| `BUILD_FAIL` | `build-<cfg>-<arch>.log` | First line matching ` error:` |
| `BUILD_TIMEOUT` | `build-<cfg>-<arch>.log` | Last non-empty line (last 20 lines checked); prefixed `last:` |
| `BOOT_FAIL-kernel-panic` | `dmesg-<cfg>-<arch>.txt` | First line matching `Kernel panic` |
| `BOOT_FAIL-oops` | `dmesg-<cfg>-<arch>.txt` | First line matching `Oops` or `BUG:` |
| `BOOT_FAIL-timeout` / `no-test-done` / `unknown` | `dmesg-<cfg>-<arch>.txt` | Last non-empty line; prefixed `last:` |
| `TEST_FAIL-N-of-M` | `vmstatus-<cfg>-<arch>.txt` | `FAILED_TESTS=` value; prefixed `failed:` |
| `KUNIT_FAIL-N-of-M` | `dmesg-<cfg>-<arch>.txt` | First `not ok` KTAP line (suite name) |

All detail strings are truncated to 120 characters.

---

## Scope

- Only `configs/archive_failed/` — `archive_passed/` is unchanged
- Only `scripts/config-archive.sh` — no pipeline changes
- Detail is regenerated each time `make config-archive` runs; not persisted
  in filenames or sidecar files

---

## Enrichment summary

At end of index generation, print:

```
[config-archive] enriched N of M failed rows with detail
```

N = rows where a non-empty detail string was found.
M = total rows in the failed index.

---

## Decisions

1. **Report files at scan time, not filename only** — filenames encode the
   category but not the specifics; the report dir is already tracked as
   `trd_abs` in the row tuple and is available to `generate_index()`.
2. **Silent fallback** — report dirs are gitignored and absent on other
   machines; aborting or marking entries as "detail unavailable" adds noise
   without benefit.
3. **Index only, no sidecar files** — the index is already regenerated from
   the on-disk archive + local reports; detail regenerates naturally.
4. **120-char truncation** — fits most error lines in a terminal; the HTML
   tooltip can show the full text but we truncate consistently.
5. **`cursor:help` on titled cells** — signals that hovering reveals detail
   without adding visible UI chrome.

---

## Files changed

| File | Change |
|---|---|
| `scripts/config-archive.sh` | Add `get_fail_detail()`, `html_attr_escape()`; extend txt + html loops for FAILED; add CSS; print enrichment summary |
| `docs/index-failure-detail-plan.md` | This file |
