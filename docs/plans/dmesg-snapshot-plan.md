# dmesg snapshot integration — Plan

Branch: `feat/dmesg-snapshot`
Start date: 2026-08-21

---

## Situation

`make dmesg` captures and analyses the host kernel's dmesg for errors and hardware issues.
It does not capture the live kernel state (clocksource, taint flags, loaded modules, LSM stack,
security knobs). The `snapshot` binary already exists and produces exactly this data, but it
is only injected into the VM initramfs — it has never been used for host-side diagnostics.

---

## Problems to Solve

1. **Missing host kernel health snapshot** — after rebooting a new localconfig build, there is
   no single-command view of key kernel state (clocksource regression, new taints, LSM changes,
   module count drift, security knob values) alongside the dmesg analysis.
2. **No regression signal for kernel state fields** — without a diff vs the previous run it is
   hard to spot that, e.g., the clocksource flipped from tsc to hpet across a kernel update.

---

## Goals

1. `make dmesg` runs the `snapshot` binary after the dmesg analysis and prints its output.
2. Snapshot output is saved to `DATA_REPO/dmesg/snapshot-<label>-<version>-<date>-<uname>.txt`.
3. A field-level diff vs the previous snapshot for the same label is printed and saved.
4. `SNAPSHOT=0` skips the snapshot step entirely.
5. If the binary is absent it is built automatically; build failure is a soft skip.

---

## Scope

Files/components changed:
- `lib/dmesg.sh` — add `run_snapshot()` after `run_analysis`; find/diff previous snapshot file
- `Makefile` — add `SNAPSHOT ?= 1`; export `SNAPSHOT`; update help text and variable list

No changes to: `tests/programs/snapshot/` (binary unchanged), VM initramfs pipeline, CI tests.

---

## Non-goals

- ARM64/riscv snapshot on host — x86_64 binary only (matches the hardware this runs on)
- Configurable field list — the 15 diff fields are hardcoded; sufficient for the use case
- Snapshot in `make all` pipeline — host-only; VM snapshot already handled by 480_snapshot test

---

## Design decisions

### Auto-build on missing binary

Rather than failing or skipping silently when the binary is absent (e.g. fresh clone),
`make -C tests/programs/snapshot` is invoked. This keeps the workflow self-healing without
requiring a separate `make programs` step. Build failure degrades to a one-line skip note.

### Diff fields

15 fields chosen for signal-to-noise ratio: HOSTNAME, INIT, FLAGS, PAGESIZE, CLOCKSOURCE,
FS, LSM, ASLR, DMESG_RESTRICT, KPTR_RESTRICT, ENTROPY, #MODULES, TAINTED, CMDLINE, ISSUES.
Volatile fields (UPTIME, LOADAVG, MEMORY, SWAP, ENTROPY numeric) are excluded except ENTROPY
(256 = getrandom seeded; change is meaningful). CMDLINE included to catch bootarg regressions.

### Snapshot file naming

`snapshot-<label>-<version>-<date>-<uname>.txt` mirrors the dmesg file naming so `find`-based
previous-file discovery works with the same sort-by-mtime pattern already used for dmesg diff.

---

## Testing strategy

- **Manual** — `make dmesg` with binary present; verify snapshot section and diff appear
- **Manual: SNAPSHOT=0** — verify snapshot section is skipped
- **Manual: missing binary** — `mv` binary away, run `make dmesg`, verify auto-build triggers
- **No CI test** — `lib/dmesg.sh` requires `sudo dmesg` and a live kernel; no mock harness

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, ≥70% decision paths

make dmesg
# Expected: dmesg analysis followed by snapshot section + diff vs previous

make dmesg SNAPSHOT=0
# Expected: snapshot section absent, analysis runs normally

make lint
# Expected: shellcheck clean, no size violations
```
