# dmesg capture and analysis — Plan

Branch: `feat/dmesg-analyze`
Start date: 2026-07-14

---

## Situation

`dmesg.sh` was a 10-line root script that captured dmesg to a timestamped file.
It had no label support, no analysis, and no integration with the Makefile.
After running rc kernels on real hardware, post-boot dmesg analysis was done
manually — no structured way to track regressions between boots.

---

## Problems to Solve

1. **No label support** — every capture went into a single namespace; stable, longterm, and linux-next dmesg files mixed with mainline ones
2. **No analysis** — raw dmesg files required manual grep to surface errors, firmware bugs, and hardware issues
3. **No diff** — no way to know whether a new warning appeared since the last capture of the same label
4. **Not in Makefile** — script was in the repo root and not reachable via `make`

---

## Goals

1. `make dmesg [DMESG_LABEL=mainline|stable|longterm|linux-next]` captures and analyses in one step
2. Analysis covers: critical errors (Oops/panic/BUG/call trace), firmware/ACPI bugs, unknown options, hardware subsystems (NVMe, Wi-Fi/mt7921e, AMD CCP/PMC/IOMMU, NVIDIA/ideapad taint)
3. Diff of warning/error lines vs previous capture for the same label with `+N new / -N resolved` summary
4. `VERDICT=CLEAN|WARNINGS|ERRORS` written to analysis file; exit 1 on ERRORS so callers can detect regressions
5. Script lives in `lib/` alongside all other pipeline scripts

---

## Scope

Files changed:
- `lib/dmesg.sh` — rewritten from 10-line stub to full capture + analysis + diff script
- `Makefile` — `dmesg` target, `DMESG_LABEL` variable, `.PHONY` entry, help text
- `.gitignore` — add `dmesg/` (captures are output, not source)
- `CLAUDE.md` — key files entry for `lib/dmesg.sh`
- `memory/workflows.md` — `DMESG_LABEL` variable row, dmesg workflow section
- `memory/project.md` — `lib/dmesg.sh` in architecture block and directory structure

No changes to: kernel build pipeline, VM tests, reports, fetch/checkout logic.

---

## Non-goals

- Parsing VM dmesg (that is `lib/vm.sh`'s job via `dmesg.txt` in the build dir)
- Automated periodic capture (cron/systemd timer — out of scope)
- Sending dmesg to LKML directly (that remains a manual step via `summary.mail.txt`)

---

## Design decisions

### Label validation

Four labels accepted: `mainline`, `stable`, `longterm`, `linux-next`. Validated at startup; unknown labels exit 2. Keeps the namespace predictable so the diff can reliably find the previous capture for the same label.

### Diff approach: strip timestamps, sort, comm

Timestamps make every dmesg line unique; stripping them before `comm -13`/`-23` lets us compare message content across boots. `sort -u` deduplicates repeated messages (e.g. repeated deauth lines). Result is a clean set diff: new warning types vs resolved ones.

### Hardware patterns scoped to this machine

Analysis patterns target the Lenovo IdeaPad Ryzen 7 5800H (mt7921e Wi-Fi, AMD CCP/PMC, NVIDIA dGPU, NVMe × 2). Future machines would require additional pattern sections.

### VERDICT drives exit code

`VERDICT=ERRORS` → exit 1; `WARNINGS` or `CLEAN` → exit 0. This makes `make dmesg` composable in CI or shell scripts without parsing the analysis file.

---

## Testing strategy

- **Label validation** — run `./lib/dmesg.sh badlabel`; expect exit 2 and error message
- **Capture** — run `make dmesg`; verify `dmesg/*.txt` and `dmesg/*-analysis.txt` created
- **Analysis content** — run against the known `dmesg-mainline-7.2-...-localconfig.txt` from 2026-07-14; verify known issues appear (CCP, Wi-Fi deauth, firmware bugs, NVIDIA taint)
- **Diff** — run twice; second run should show `+0 new, -0 resolved` (no change between identical boots)
- **shellcheck** — enforced by pre-commit and pre-push hooks

---

## Testing commands

```sh
# 1. Label validation
bash lib/dmesg.sh badlabel
# Expected: error message, exit 2

# 2. Full capture + analysis
make dmesg
# Expected: dmesg/*.txt and dmesg/*-analysis.txt written; VERDICT printed

# 3. Diff on second run (no change expected)
make dmesg
# Expected: summary: +0 new, -0 resolved  (or small delta for new kernel messages)

# 4. Shellcheck (run by pre-push hook)
shellcheck lib/dmesg.sh
# Expected: no output, exit 0
```
