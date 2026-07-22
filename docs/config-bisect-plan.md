# Design: Config Bisect (`make bisect`)

## Problem

`configs/archive_failed/` contains rand500config boot failures with 500 random options
on top of tinyconfig. These are dead ends — too many options to reason about manually,
not actionable for LKML. A bisect narrows a 500-option failure to the responsible
option(s) in ~9 build+boot iterations.

**Impact:** 20 of 34 unique failing configs in the archive are undiagnosed rand500config
boot failures where bisect directly applies.

---

## Design Decisions

| Question | Decision | Rationale |
|---|---|---|
| Failure scope | BOOT_FAIL + BUILD_FAIL | Covers all rand500config failures; BUILD_FAIL is faster (no boot) |
| Option extraction | Diff archived config vs fresh tinyconfig+bootability baseline | Works for any archived config, no stale build/ artifacts needed |
| Single-option verify | Yes — always verify alone | Adds one build but proves the LKML report is clean |
| Interaction fallback | Report smallest failing subset, flag as 'interaction' | Far more useful than 500 options; easy to narrow manually |
| Storage | `bisect/<timestamp>-<config>-<arch>-<sha256>/` at repo root | Parallel to reports/; gitignored; full SHA makes it traceable back to the archive |
| Per-step records | fragment.config + build.status + vm.status + dmesg + step.txt + build.log | Full artifact set per half at each step |
| Auto-archive reproducer | Yes — to `configs/archive_failed/` with `-bisect-minimal` suffix | Replaces 500-option config with minimal one |
| Resume | Yes — detect completed steps, skip them | Bisect can take 30–60 min; Ctrl-C should not throw away work |
| Make interface | `make bisect CONFIG_FILE=<path>` with arch auto-detected | Same pattern as `make replay` |
| Baseline verification | Yes — always verify tinyconfig+bootability passes first | Prevents false results from a broken baseline |
| BUILD_FAIL detection | Build exit code + error message match | Confirms same failure, not just any build error |
| Live progress | Yes — print step result as each half completes | User can monitor a long run |
| FINDINGS.md | No — print draft to stdout, user decides | User adds context before committing |
| Non-reproduction | Abort with clear message (may be fixed) | Accurate; sanity check catches this before wasting 9 builds |
| DRY_RUN=1 | Yes — prints option count, estimated steps, candidate list | Consistent with kconfig-build; lets user verify before committing |

---

## Algorithm

```
Input: archived .config (N candidate options above tinyconfig+bootability baseline)

Candidate extraction:
  1. Generate fresh tinyconfig + rand500config.config baseline for arch
  2. candidates = OPTIONS(archived) − OPTIONS(baseline)

Sanity checks:
  3. Verify baseline (0 options)    → must PASS
  4. Verify full archived config    → must FAIL (abort if fixed)
     For BUILD_FAIL: capture first error: line as error_pattern

Binary search:
  5. Split candidates into left (first half) and right (second half)
  6. Test left half (tinyconfig + bootability + left options):
       FAIL → culprit in left; mark right 'skipped'; recurse on left
       PASS → test right half:
                FAIL  → culprit in right; recurse on right
                PASS  → interaction; stop, report smallest failing set
  7. Repeat until 1 candidate remains

Verification:
  8. Test single remaining candidate alone
       FAIL → minimal single-option reproducer found
       PASS → interaction with something discarded; report minimum_set

Output:
  9. result.config  — minimal reproducer (single option or minimum set)
 10. Archive to configs/archive_failed/ with -bisect-minimal suffix
 11. Print draft FINDINGS.md entry to stdout
```

Expected iterations: `ceil(log2(500)) ≈ 9` for a 500-option config.

---

## Step Directory Structure

```
bisect/<timestamp>-<config>-<arch>-<sha256>/
  .baseline_options.txt     # sorted CONFIG_X=y from tinyconfig+bootability (generated once)
  .candidates.txt           # candidate option list (diff: archived − baseline)
  .error_pattern.txt        # first error: line from BUILD_FAIL verification (if applicable)
  bisect.log                # (stdout is the log — no separate file needed)

  step-00-baseline/         # sanity check: tinyconfig+bootability alone
    seed.config             # generated full .config
    build.status            # STATUS=PASS expected
    vm.status               # BOOT=PASS expected (BOOT_FAIL cases)
    dmesg.txt               # serial output
    build.log               # combined build+boot stdout
    step.txt                # "Baseline: 0 option(s) → PASS"
    result                  # "PASS"

  step-00-full/             # sanity check: full archived config
    options.txt             # copy of archived config
    build.status
    vm.status
    dmesg.txt
    build.log
    step.txt                # "Full config: 500 option(s) → FAIL (Boot timeout after 60s)"
    result                  # "FAIL"

  step-01-left/             # bisect step 1, left half (options 1–250)
    options.txt             # the 250 option lines tested
    seed.config             # generated full .config used for this step
    build.status
    vm.status               # only for BOOT_FAIL cases
    dmesg.txt               # only for BOOT_FAIL cases
    build.log
    step.txt                # "Step 1/9 left: 250 option(s) → FAIL (Timeout after 60s)"
    result                  # "FAIL" or "PASS" or "skipped (culprit in left half)"

  step-01-right/            # bisect step 1, right half (options 251–500)
    options.txt             # always written, even if skipped
    [seed.config ...]       # only if tested
    step.txt                # "Step 1/9 right: 250 option(s) → skipped (culprit in left)"
    result                  # "skipped (culprit in left half)" or "FAIL" or "PASS"

  step-02-left/ ...         # subsequent steps, same structure

  step-verify/              # single-option verification
    options.txt             # the one suspect option
    seed.config
    build.status
    vm.status
    dmesg.txt
    build.log
    step.txt                # "Verify (single): 1 option(s) → FAIL (CONFIG_X confirmed alone)"
    result                  # "FAIL" or "PASS"

  suspect.txt               # single remaining candidate (before verification)
  minimum_set.txt           # smallest known failing set (interaction case)
  result_type.txt           # "single" or "interaction"
  result.config             # final minimal reproducer .config
```

---

## Files

| File | Role |
|---|---|
| `scripts/config-bisect.sh` | Main bisect driver — parsing, extraction, search loop, reporting |
| `Makefile` target `bisect` | Entry point: validates CONFIG_FILE, exports env, calls the script |
| `bisect/` | Run artifacts (gitignored) |
| `configs/archive_failed/` | Destination for minimal reproducer (`-bisect-minimal` suffix) |

---

## Usage

```sh
# Preview the bisect plan without building
make bisect CONFIG_FILE=configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-b7e535b...-BOOT_FAIL-no-console.config DRY_RUN=1

# Run the bisect
make bisect CONFIG_FILE=configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-b7e535b...-BOOT_FAIL-no-console.config

# Bisect resumes automatically if interrupted — just re-run the same command
```

Expected output (live):
```
[bisect] Step 1/9 left: 250 option(s) → FAIL (Timeout after 60s)
[bisect] Step 2/9 left: 125 option(s) → PASS
[bisect] Step 2/9 right: 125 option(s) → FAIL (Timeout after 60s)
...
[bisect] Step 9/9 left: 1 option(s) → FAIL (Timeout after 60s)

=== Bisect Result ===
Responsible option:  CONFIG_RCU_SCALE_TEST
Arch:                i386
Failure type:        BOOT_FAIL-timeout
Minimal reproducer:  bisect/2026-07-22_10-00-00-rand500config-i386-b7e535b8/result.config
Archived:            configs/archive_failed/kconfig-rand500config-i386-v7.2-rc4-<sha>-BOOT_FAIL-timeout-bisect-from-b7e535b8.config
```
