# feat/config-archive — Plan

Branch: `feat/config-archive`
Start date: 2026-07-18

---

## Problem

`reports/` accumulates hundreds of run directories. Each contains `kconfig-<config>-<arch>.config`
files that represent the exact kernel config used for that run, together with the SHA256
fingerprint and pass/fail outcome. There is currently no way to:

- Browse which configs are known-good across kernel versions
- See which configs failed and why, without opening individual `summary.txt` files
- Deduplicate configs that appear in many runs (same SHA256, repeated tests)

---

## Proposed Solution

A script `scripts/config-archive.sh` scans all `reports/*/` directories and populates two
committed archive directories:

| Directory | Contents |
|---|---|
| `configs/archive_passed/` | One `.config` per unique SHA256 that has ever produced a PASS result |
| `configs/archive_failed/` | One `.config` per unique SHA256 that has only ever produced FAIL results |

Run via `make config-archive`. Both directories are committed to the repo so they form a
browsable, versioned record.

---

## Filename Scheme

**Passed:**
```
kconfig-<config>-<arch>-<version>-<SHA256>.config
```
Example:
```
kconfig-tinyconfig-x86_64-v7.2-rc2-656a05e527fd0c569948e855cd0792eea20785344f33824af9ebaa6b57a7d1fd.config
```

**Failed:**
```
kconfig-<config>-<arch>-<version>-<SHA256>-<STAGE>-<SYMPTOM>.config
```
Examples:
```
kconfig-tinyconfig-arm64-v7.2-rc2-8d4e4891...-BOOT_FAIL-no-test-done.config
kconfig-rand500config-x86_64-v7.2-rc2-...-BOOT_FAIL-kernel-panic.config
kconfig-rand500config-i386-v7.2-rc2-...-BOOT_FAIL-oops.config
kconfig-randconfig-x86_64-v7.2-rc2-...-BUILD_TIMEOUT.config
```

---

## Failure Reason Mapping

Derived from `summary.txt` table (Build/Boot columns + Notes) per (config, arch):

| Condition | STAGE-SYMPTOM |
|---|---|
| Build column = `FAIL` | `BUILD_FAIL` |
| Build column = `TIMEOUT` | `BUILD_TIMEOUT` |
| Boot column = `FAIL`, Notes contains "panic" | `BOOT_FAIL-kernel-panic` |
| Boot column = `FAIL`, Notes contains "Oops" | `BOOT_FAIL-oops` |
| Boot column = `FAIL`, Notes contains "TEST_DONE not reached" or "Init started" | `BOOT_FAIL-no-test-done` |
| Boot column = `FAIL`, other | `BOOT_FAIL-unknown` |
| Boot = PASS, TESTS_FAIL > 0 (from vmstatus) | `TEST_FAIL-N-of-M` |
| Boot = PASS, KUNIT_FAIL > 0 (from vmstatus) | `KUNIT_FAIL-N-of-M` |

---

## Deduplication Logic

SHA256 is the identity key. Processing order:

1. Scan all reports, collecting every (SHA256, config, arch, version, status, reason) tuple.
2. Build a set of SHA256 hashes that appear with status=PASS in at least one run.
3. Write `configs/archive_passed/`: one file per unique passing SHA256 (first seen version used for naming).
4. Write `configs/archive_failed/`: one file per unique failing SHA256 **not** in the passed set.

A config that failed early in development but later passed appears only in `archive_passed/`.

---

## Data Sources

All data read from within each `reports/<run>/` directory — no dependency on `build/`:

| Source | Used for |
|---|---|
| `summary.txt` | Kernel version, Build/Boot status per (config, arch), Notes, SHA256 fingerprint |
| `kconfig-<config>-<arch>.config` | The config file to copy into the archive |
| `vmstatus-<config>-<arch>.txt` | TESTS_FAIL, KUNIT_FAIL counts (for TEST_FAIL/KUNIT_FAIL reason) |

Kernel version is extracted from the report directory name
(`mainline-7.2-2026-07-18_14-10-14-v7.2-rc3` → `v7.2-rc3`).

---

## Files Changed

| File | Change |
|---|---|
| `scripts/config-archive.sh` | New: scans reports/, populates archive dirs |
| `configs/archive_passed/` | New directory (committed); gitkeep or first archive run |
| `configs/archive_failed/` | New directory (committed); gitkeep or first archive run |
| `Makefile` | Add `config-archive` target + `.PHONY` entry + help entry |
| `CLAUDE.md` | Document archive dirs and `make config-archive` |
| `memory/workflows.md` | Add `make config-archive` to Common Workflows |
| `memory/project.md` | Add archive dirs to Directory Structure |

---

## Decisions

1. **Committed directories** — `configs/archive_passed/` and `configs/archive_failed/` are
   committed so the archive is browsable on GitHub without running the script
2. **Deduplicate by SHA256; passed wins** — a config is permanently graduated to `archive_passed/`
   once any run using it succeeds; later failures with the same config don't add to `archive_failed/`
3. **On-demand via `make config-archive`** — not wired into `make all`; avoids adding latency
   to every pipeline run; run manually after accumulating new reports
4. **Stage + symptom for failure names** — short enough to be useful at a glance in a directory
   listing; derived from Build/Boot columns + Notes in `summary.txt`
5. **Source: `summary.txt` + `vmstatus`** — avoids reading `build/` (gitignored, absent on CI);
   all needed data is already in the report directory
6. **Full SHA256 in filename** — unambiguous identity; allows instant dedup check via `ls`

---

## Alternatives Considered

### Index file instead of filename-encoded reason

A separate `index.txt` or CSV tracking all runs per SHA256. Pro: richer history, queries
possible. Con: extra file to maintain; the filename approach is self-contained and
immediately readable in a directory listing.

### Gitignore the archive (local-only)

Same as `reports/` — generated locally, never committed. Pro: no repo bloat. Con: loses
the benefit of a browsable GitHub view and version-controlled history of known-good configs.

### Auto-update after `make all`

Archive rebuilt after every pipeline run. Pro: always current. Con: scans all 155+ runs on
every invocation; adds 1–2 s latency; unnecessary when only one new run was added. The
on-demand `make config-archive` is preferable.
