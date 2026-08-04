# Consolidation Workflow

Each kernel-test clone (mainline, stable, stable-rc, next) on each machine
(local, Hetzner) accumulates failures independently.  The consolidation workflow
merges all per-source failure indexes into one unified view so you can spot
cross-machine reproducibility and pick the next issue to investigate.

`consolidation/` is gitignored — data stays local.  Only the small `index.txt`
files (not `.config` files or build logs) need to be transferred between machines.

---

## Source labels

| Directory name      | Machine  | Clone                  |
|---------------------|----------|------------------------|
| `local-mainline`    | local    | kernel-test            |
| `local-stable`      | local    | kernel-test-stable     |
| `local-stable-rc`   | local    | kernel-test-stable-rc  |
| `local-next`        | local    | kernel-test-next       |
| `hetzner-mainline`  | Hetzner  | kernel-test            |
| `hetzner-stable`    | Hetzner  | kernel-test-stable     |
| `hetzner-stable-rc` | Hetzner  | kernel-test-stable-rc  |
| `hetzner-next`      | Hetzner  | kernel-test-next       |

Only populate directories that actually have data — absent sources are silently
skipped by `make consolidate-index`.

---

## Step 1 — Update the config archive (per clone)

Run this in every clone that has accumulated new test results:

```sh
make config-archive
# writes configs/archive_failed/index.txt + configs/archive_passed/index.txt
```

---

## Step 2 — Gather index files (local clones)

Copy each local clone's `archive_failed/index.txt` into the correct source
subdirectory under `consolidation/`:

```sh
cd ~/git/kernel-test   # this repo

SOURCE=local-mainline
mkdir -p consolidation/${SOURCE}/archive_failed
cp ~/git/kernel-test/configs/archive_failed/index.txt \
   consolidation/${SOURCE}/archive_failed/index.txt

SOURCE=local-stable
mkdir -p consolidation/${SOURCE}/archive_failed
cp ~/git/kernel-test-stable/configs/archive_failed/index.txt \
   consolidation/${SOURCE}/archive_failed/index.txt

SOURCE=local-stable-rc
mkdir -p consolidation/${SOURCE}/archive_failed
cp ~/git/kernel-test-stable-rc/configs/archive_failed/index.txt \
   consolidation/${SOURCE}/archive_failed/index.txt

SOURCE=local-next
mkdir -p consolidation/${SOURCE}/archive_failed
cp ~/git/kernel-test-next/configs/archive_failed/index.txt \
   consolidation/${SOURCE}/archive_failed/index.txt
```

---

## Step 3 — Gather index files (Hetzner)

`scp` the `index.txt` files over — no need to transfer `.config` files or logs:

```sh
cd ~/git/kernel-test

mkdir -p consolidation/hetzner-mainline/archive_failed
scp hetzner:~/git/kernel-test/configs/archive_failed/index.txt \
    consolidation/hetzner-mainline/archive_failed/

mkdir -p consolidation/hetzner-stable/archive_failed
scp hetzner:~/git/kernel-test-stable/configs/archive_failed/index.txt \
    consolidation/hetzner-stable/archive_failed/

mkdir -p consolidation/hetzner-stable-rc/archive_failed
scp hetzner:~/git/kernel-test-stable-rc/configs/archive_failed/index.txt \
    consolidation/hetzner-stable-rc/archive_failed/

mkdir -p consolidation/hetzner-next/archive_failed
scp hetzner:~/git/kernel-test-next/configs/archive_failed/index.txt \
    consolidation/hetzner-next/archive_failed/
```

Replace `hetzner` with your SSH host alias from `~/.ssh/config`.

---

## Step 4 — Merge

```sh
make consolidate-index
# → consolidation/index.txt
# → consolidation/index.html
```

Re-run any time after updating a source index.

---

## Reading the output

Open `consolidation/index.html` in a browser.

| Column | Meaning |
|--------|---------|
| Source | Which machine and clone produced this failure |
| Config | Kernel config profile (`rand500config`, `allmodconfig`, …) |
| Arch   | Target architecture |
| Version | Kernel tag (`v7.2-rc5`, `v7.1.4`, …) |
| Failure reason | `BUILD_FAIL`, `BUILD_TIMEOUT`, `BOOT_FAIL-*`, `KUNIT_FAIL-N-of-M` |
| SHA256 | Config fingerprint — same SHA from two sources = cross-machine confirmation |

**Hover** over the failure reason cell to see the detail line extracted from the
original report (e.g. the specific linker error or test that failed).

**Click** the source name to open that source's `archive_failed/index.html` for
the full per-source listing.

---

## Deciding which issue to investigate next

Look for:

1. **`BUILD_FAIL` in multiple sources** — cross-machine reproducibility rules out
   transient failures and confirms the bug is real.
2. **`BOOT_FAIL-kernel-panic` or `BOOT_FAIL-oops`** — higher severity than build
   failures; usually has a clear dmesg trail.
3. **Same SHA across multiple versions** — the bug persists across releases.
4. **Failures on multiple arches** — broader impact, stronger case for an upstream
   patch.

Compare against `FINDINGS.md` (when present) to avoid re-investigating known
issues.  For `BUILD_FAIL` entries: replay the archived config to reproduce, then
use `make bisect` or `make verify-patch` to isolate and fix.
