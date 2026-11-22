# Consolidate config archives — Plan

Branch: `feat/consolidate-config-archives`
Start date: 2026-08-02

---

## Situation

Config archives (`configs/archive_failed/`, `configs/archive_passed/`) and latest
reports accumulate independently in each kernel-test clone across two machines
(local + Hetzner staging) and four clone types (mainline, stable, stable-rc,
next). There is no unified view of failures across sources. To decide which bug
to work on next you have to manually check up to 8 separate repositories.

Consolidating into one branch enables pattern detection, cross-version comparison,
and informed priority decisions from a single index.

---

## Goals

1. Define a canonical directory structure under `consolidation/` for per-source data
2. Each source (machine × clone) contributes its data by pushing to this branch manually
3. A `make consolidate-index` target merges all per-source failure indexes into one unified `consolidation/index.txt` + `consolidation/index.html` with a SOURCE column
4. The unified index is the decision surface for choosing the next issue to work on

---

## Directory structure

```
consolidation/
  <machine>-<label>/            one subdirectory per source
    archive_failed/             copy of configs/archive_failed/ from that clone
    archive_passed/             copy of configs/archive_passed/ from that clone
    reports/                    latest report dir only (one subdir)
  index.txt                     merged failure index — all sources, SOURCE column added
  index.html                    HTML version of the merged index
```

### Source labels

| Directory name | Machine | Clone |
|---|---|---|
| `local-mainline` | local | kernel-test (mainline -rc) |
| `local-stable` | local | kernel-test-stable |
| `local-stable-rc` | local | kernel-test-stable-rc |
| `local-next` | local | kernel-test-next |
| `hetzner-mainline` | Hetzner staging | kernel-test (mainline -rc) |
| `hetzner-stable` | Hetzner staging | kernel-test-stable |
| `hetzner-stable-rc` | Hetzner staging | kernel-test-stable-rc |
| `hetzner-next` | Hetzner staging | kernel-test-next |

Only populate directories that actually have data — absent sources are silently
skipped by the index script.

---

## How to contribute data from a source

On each machine, in each clone directory:

```sh
# 1. Ensure archives are up to date
make config-archive

# 2. In the kernel-test repo (this repo), on the consolidation branch:
cd ~/git/kernel-test
git checkout feat/consolidate-config-archives

# 3. Copy data into the correct source subdirectory
SOURCE=local-mainline   # adjust per machine/clone
mkdir -p consolidation/${SOURCE}/archive_failed
mkdir -p consolidation/${SOURCE}/archive_passed
mkdir -p consolidation/${SOURCE}/reports

rsync -a ~/git/<clone>/configs/archive_failed/ consolidation/${SOURCE}/archive_failed/
rsync -a ~/git/<clone>/configs/archive_passed/ consolidation/${SOURCE}/archive_passed/

# Latest report only (most recently modified)
latest=$(ls -td ~/git/<clone>/reports/mainline-*/ 2>/dev/null | head -1)
[[ -n $latest ]] && rsync -a "$latest" consolidation/${SOURCE}/reports/

# 4. Commit and push
git add consolidation/${SOURCE}/
git commit -m "chore(consolidation): add ${SOURCE} archives and latest report"
git push origin feat/consolidate-config-archives
```

For Hetzner: add this repo as a remote on the Hetzner machine, then push the
consolidation branch directly:

```sh
# On Hetzner, once:
git remote add kernel-test git@github.com:bb-claw/kernel-test.git

# Then after copying data:
git push kernel-test feat/consolidate-config-archives
```

---

## Unified index generation

A new script `scripts/consolidate-index.sh` reads all
`consolidation/*/archive_failed/index.txt` files, prepends a `SOURCE` column,
merges and sorts by version + config, and writes:

- `consolidation/index.txt` — plain text table
- `consolidation/index.html` — HTML table with the existing index.html style

Output format (added SOURCE column at the start):

```
SOURCE              CONFIG           ARCH    VERSION     FAILURE REASON              ...
────────────────────────────────────────────────────────────────────────────────────
local-mainline      allmodconfig     arm64   v7.2-rc4    BUILD_FAIL                  ...
hetzner-stable-rc   allmodconfig     arm64   v7.1.5-rc2  BUILD_TIMEOUT               ...
local-stable-rc     randconfig       x86_64  v7.1.5-rc2  BUILD_FAIL                  ...
```

Run via:

```sh
make consolidate-index
```

Or standalone:

```sh
scripts/consolidate-index.sh
```

---

## Scope

Files to add/change:

- `consolidation/` — new directory (gitignored content except index files? or fully committed?)
- `scripts/consolidate-index.sh` — new script: merge per-source index.txt files
- `Makefile` — new `consolidate-index` target
- `CLAUDE.md` — document new directory and target

**Open question before implementing:** should the `.config` files themselves be
committed to this repo (they can be hundreds of KB each, many files), or only
the `index.txt` / `index.html` per source plus the merged index? The per-source
`index.txt` files are small (~5 KB) and sufficient for decision-making. The
`.config` files are only needed if you want to `make replay` directly from this
repo.

---

## Non-goals

- Automated sync / cron job between machines (manual push is sufficient for now)
- De-duplicating failures that appear in multiple sources (show all, let the
  human decide if the same SHA from two sources is interesting)
- Merging `archive_passed/` into a unified index (passed configs are for replay,
  not decision-making; keep separate)

---

## Decision surface: choosing the next issue

Once `consolidation/index.txt` is populated, look for:

1. **`BUILD_FAIL` appearing across multiple sources** — cross-machine/version reproducibility confirms the bug is real and not a transient fluke
2. **New `BUILD_FAIL` entries not in FINDINGS.md** — bugs not yet known or tracked
3. **`BOOT_FAIL` with a clear symptom** (kernel-panic, oops) — higher severity than build failures
4. **Failures on multiple arches** — broader impact, stronger motivation for an upstream patch

Compare against `FINDINGS.md` to avoid re-investigating known issues.
