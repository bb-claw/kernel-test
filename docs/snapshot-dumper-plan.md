# Snapshot Dumper — Plan

Branch: `feat/snapshot-dumper`
Start date: 2026-08-11
Status: IN PROGRESS

---

## Situation

The test suite captures serial output (`dmesg.txt`) for every VM run, but extracting
structured machine information (kernel version, memory, taint state) from a long serial
log is fragile. A dedicated C binary that runs at boot, reads /proc and calls uname(2),
and writes a compact structured report gives the harness a stable artifact to validate
and archive alongside test results.

This is also a learning project: the C program is written incrementally by the author
to build familiarity with /proc traversal, syslog(2), and structured output in C.

---

## Goals

1. Add `tests/programs/snapshot/snapshot.c` — a C binary the author writes in tiers.
2. Add `tests/programs/snapshot/Makefile` — cross-compile for 4 arches, Clang gate.
3. Inject the binary into the initramfs; run it early in `/init` before the test loop.
4. Add `tests/custom/480_snapshot.sh` — validates the output file `/tmp/snapshot.txt`.
5. Add `tests/ci/test-snapshot.sh` — CI build + behavioral test.
6. Wire into `lib/initramfs.sh` and `lib/bootstrap.sh`.

---

## Scope

Files changed:
- `tests/programs/snapshot/snapshot.c`    — C program (author-written, incrementally)
- `tests/programs/snapshot/Makefile`      — cross-compile for 4 arches, clang gate
- `tests/programs/Makefile`               — add `snapshot` to recursive `make all`
- `tests/custom/480_snapshot.sh`          — in-VM validation of /tmp/snapshot.txt
- `lib/initramfs.sh`                      — run snapshot in /init + inject binary
- `lib/bootstrap.sh`                      — build snapshot after syscall-tests
- `tests/ci/test-snapshot.sh`             — Tier 2 CI: build + behavioral
- `memory/test-inventory.md`              — add row 480_, update next slot to 490_

No changes to: configs/, existing test scripts, report/vm pipeline.

---

## Non-goals

- No network push in v1 — file write only (`/tmp/snapshot.txt`)
- No report.sh integration in v1 — snapshot is read by the test script; the content
  appears in `dmesg.txt` via the test script's print statements
- No /sys enumeration or device-tree walking — deferred (see Tier 3 / Defer below)
- No --output FILE flag in v1 skeleton — /init redirects stdout to file

---

## C Program — Tiered Implementation Plan

The binary is written by the author in tiers. Each tier adds data sources.
The skeleton compiles and emits section headers with placeholder content;
as each tier is implemented the content becomes real.

### Output format

```
=== SNAPSHOT ===
=== UNAME ===
sysname: Linux
release: 7.2.0-rc7
machine: x86_64
=== UPTIME ===
3.14 1.23
=== CMDLINE ===
console=ttyS0,115200 root=/dev/ram0 rdinit=/init
=== TAINTED ===
0
=== DMESG ===
[    0.000000] Linux version ...
...
=== MEMINFO ===
MemTotal:         524288 kB
MemFree:          510100 kB
...
=== LOADAVG ===
0.00 0.00 0.00 1/1 42
=== MODULES ===
(empty or module list)
snapshot_ok=1
```

### Tier 1 — implement first (high value, low complexity)

| # | Source | Syscall/API | Notes |
|---|---|---|---|
| 1 | Kernel version/arch | `uname(2)` → `struct utsname` | ~5 lines; foundation of every snapshot |
| 2 | Time since boot | read `/proc/uptime` | trivial file read; two space-separated floats |
| 3 | Kernel command line | read `/proc/cmdline` | trivial; confirms correct kernel/config booted |
| 4 | Taint flags | read `/proc/sys/kernel/tainted` | single integer; cheap panic/oops signal |

### Tier 2 — next (high value, moderate complexity)

| # | Source | Syscall/API | Notes |
|---|---|---|---|
| 5 | Kernel ring buffer | `syslog(SYSLOG_ACTION_READ_ALL, buf, len)` | needs correct buffer sizing (`SYSLOG_ACTION_SIZE_BUFFER`); the most valuable payload |
| 6 | Memory stats | read `/proc/meminfo` | flat key:value; useful for flakiness correlation (OOM vs real bug) |

### Tier 3 — add once v1 works

| # | Source | Syscall/API | Notes |
|---|---|---|---|
| 7 | Load averages | read `/proc/loadavg` | trivial; low individual value but cheap alongside meminfo |
| 8 | Loaded modules | read `/proc/modules` | simple line parse; useful for VF2 hardware-specific tests |

### Deferred — real complexity, uncertain payoff now

- `/proc/interrupts` — variable-width columns, arch-specific IRQ names
- `/sys/class/*` enumeration — directory tree walk, lots of error handling
- Device-tree model string (`/proc/device-tree/model`) — only meaningful on arm64/riscv
- Network push — requires a TCP socket and a listener on the host

---

## Design Decisions

### Run at boot, not as a test subcommand

snapshot runs in `/init` before the test loop, writing to `/tmp/snapshot.txt`.
This captures dmesg before any test scripts add output to the ring buffer.
The 480_ test script validates the file; it does not re-run the binary.
If the file is absent (binary not built), the test skips cleanly.

### No capability marker

snapshot has no external kernel-config dependency (uname/proc/syslog are always
present). The binary is always injected when built; the test skips on absent binary.
This mirrors the syscall-tests pattern (no marker, runtime skip).

### Output to stdout, redirected by /init

The binary writes to stdout. `/init` redirects to `/tmp/snapshot.txt`. This keeps
the binary simple (no file-open boilerplate in v1) and lets CI run it directly
(`snapshot > out.txt`) without special flags.

### Section headers as test anchors

Each data source gets a `=== NAME ===` header even in the skeleton (which emits
placeholder content). The test script checks for these headers, so the test passes
immediately with the stub and continues to pass as tiers are implemented. Content
assertions are added per-tier as the author completes each one.

### Clang quality gate (x86_64 only)

Same pattern as arena-test and syscall-tests: `musl-gcc` for all 4 arches (shipped),
`musl-clang` for x86_64 only (quality gate, not shipped). Clang's
`-Weverything` catches sign-conversion, buffer arithmetic, and implicit casts
before they become runtime bugs.

---

## Test Script Logic (480_snapshot.sh)

```
binary present?  → no  → skip (make bootstrap not run)
/tmp/snapshot.txt exists? → no → fail
=== SNAPSHOT === header?  → no → fail
=== UNAME ===  header?    → no → fail
=== UPTIME ===  header?   → no → fail
=== CMDLINE === header?   → no → fail
=== TAINTED === header?   → no → fail
=== DMESG ===   header?   → no → fail
=== MEMINFO === header?   → no → fail
snapshot_ok=1?            → no → fail (binary crashed mid-run)
```

Content assertions added per-tier:
- After Tier 1: `Linux` in UNAME, uptime float format, tainted=0
- After Tier 2: MemTotal in MEMINFO, non-empty DMESG

---

## CI Test (test-snapshot.sh)

```
source files present?              → assert
musl available?  → build all arches, verify binaries, Clang gate
binary available? → no → finish + exit 0 (skip behavioral tests)
binary exits 0?                    → assert
output has =SNAPSHOT= header?      → assert
output has =UNAME= header?         → assert
output has snapshot_ok=1?          → assert
```

---

## Testing Commands

```sh
# Build
make -C tests/programs/snapshot

# Clang quality gate
make -C tests/programs/snapshot bin/x86_64/snapshot-clang

# CI
make ci-test  # includes test-snapshot.sh

# In-VM smoke (kunitconfig + tinyconfig, 4 archs)
make smoke NO_FETCH=1
# Expected: PASS 50/50 (or 49/49 skip on tinyconfig without bootstrap)

# Full verification
make all NO_FETCH=1 CONFIGS=tinyconfig
```
