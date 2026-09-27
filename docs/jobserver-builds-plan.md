# GNU Make Jobserver Builds — Plan

Branch: `feat/jobserver-builds`
Prerequisite: `feat/parallel-builds` merged to `main` ✓
Status: **ready to implement**

---

## Situation

`feat/parallel-builds` runs up to `PARALLEL_BUILDS=4` concurrent kernel builds, each at a
static `-j = nproc/PARALLEL_BUILDS` (floor 2). At the end of each tier the last surviving
build holds its original reduced `-j` while the other slots are empty:

```
Hetzner (8 cores, PARALLEL_BUILDS=4):
  tier-0 full:  4 builds × -j2 = 8 jobs  (fully utilised)
  tier-0 end:   1 build  × -j2 = 2 jobs  (6 cores idle)

Laptop (16 cores, PARALLEL_BUILDS=4):
  tier-0 full:  4 builds × -j4 = 16 jobs  (fully utilised)
  tier-0 end:   1 build  × -j4 =  4 jobs  (12 cores idle)
```

**Root cause:** `lib/build.sh` passes `-j"$NPROC"` explicitly to `kmake`, which
disconnects the kernel build from the GNU make jobserver and creates a private N-slot pool.
Freed tokens from finished siblings never reach the straggler.

---

## Prerequisite Check: FD Inheritance ✓

Run before starting implementation. Result on laptop (make 4.4.1):

```
MAKEFLAGS in shell: -j4 --jobserver-auth=fifo:/tmp/GMfifo144670
inner make: a done  b done  c done  d done  (all 4 parallel, no warning)
```

**Finding:** make 4.2+ uses `--jobserver-auth=fifo:/path` — a named FIFO on the
filesystem. Named FIFOs are opened by path, not by inherited FD number, so there is no
`O_CLOEXEC` problem. Shell scripts see the FIFO path in `MAKEFLAGS` and inner makes open
it directly. The approach works without any workaround.

**Make version requirement:** ≥ 4.2 for FIFO-based jobserver. Make < 4.2 used
`--jobserver-fds=R,W` (raw pipe FDs, closed across `exec()`). Check on Hetzner:
```sh
make --version
```
Ubuntu 22.04 ships make 4.3.1 — confirmed safe. Verify before implementing on any new host.

---

## Solution: GNU Make Jobserver

The jobserver is a Unix pipe (or named FIFO on make ≥ 4.2) holding `nproc` tokens.
Before spawning any compile job, make must acquire a token; on completion it returns one.
An empty pipe blocks until a token is released. Child makes without an explicit `-jN`
inherit the FIFO path via `MAKEFLAGS --jobserver-auth=fifo:/path` and draw from the same
pool.

When 3 of 4 builds finish, their tokens return to the FIFO. The straggler's make reads
them immediately and spawns additional compile jobs up to the full `nproc` limit.

---

## Goals

1. Straggler builds automatically absorb freed tokens up to `nproc`.
2. `PARALLEL_BUILDS` is preserved as a queue-depth cap (max concurrent builds launched) — separate from the per-job token pool.
3. `build.sh` auto-detects jobserver and falls back to `-j$(nproc)` for standalone invocations (no jobserver in `MAKEFLAGS`).
4. `NO_JOBSERVER=1` in `local.mk` reverts to static `-jN` behaviour.
5. Tier-0 / tier-1 `_flush` barrier preserved — correctness requirement for sibling config cache.
6. All three orchestration loops (build, initramfs, test) restructured to per-combo make targets for consistency; PARALLEL_VMS stays as-is (QEMU VMs are not make jobs).

---

## Scope

### Commit 1 — Makefile: per-combo make targets + jobserver top-level

Add `build-$config-$arch` targets; top-level `build:` calls `$(MAKE) -j$(nproc)` on them.
The `$(MAKE)` recursion keeps jobserver pipe FDs live for each `build.sh` subprocess.
Keep `PARALLEL_BUILDS` as a cap: `build:` limits the number of targets it passes to
`$(MAKE)` per batch (tier-0 then tier-1, flushing between).

Repeat the same pattern for `initramfs:` and `test:` loops.

Files: `Makefile`

### Commit 2 — build.sh: jobserver detection + NO_JOBSERVER escape hatch

Replace the static `NPROC` computation with a conditional:

```bash
if [[ "${NO_JOBSERVER:-0}" == 1 || "$MAKEFLAGS" != *--jobserver-auth* ]]; then
    # Standalone invocation or NO_JOBSERVER=1: use full nproc
    _build_j="-j$(( _host_cpus / ${PARALLEL_BUILDS:-1} < 2
                     ? 2 : _host_cpus / ${PARALLEL_BUILDS:-1} ))"
else
    # Jobserver active: omit -j; kernel make inherits token pool
    _build_j=""
fi
kmake --timed ${_build_j:+"$_build_j"} "$KERNEL_IMAGE_NAME" || BUILD_EXIT=$?
```

Files: `lib/build.sh`

### Commit 3 — CI tests

`tests/ci/test-jobserver.sh` — 6 static checks:
1. `build-$config-$arch` target pattern in Makefile
2. Top-level `build:` uses `$(MAKE).*nproc` (jobserver token pool)
3. No unconditional `-j"$NPROC"` in the `kmake` bzImage call in build.sh
4. `--jobserver-auth` detection present in build.sh
5. Fallback `-j$(nproc)` present in build.sh (standalone path)
6. `NO_JOBSERVER` escape hatch present in build.sh

Files: `tests/ci/test-jobserver.sh`

### Commit 4 — Docs + memory

Update `docs/jobserver-builds-plan.md` status to implemented.
Update `memory/project.md` key decision row.
Update `memory/workflows.md` variable table (`NO_JOBSERVER`).

Files: `docs/jobserver-builds-plan.md`, `memory/project.md`, `memory/workflows.md`

---

## Design Decisions

### PARALLEL_BUILDS stays as queue-depth cap

`PARALLEL_BUILDS` and the jobserver are orthogonal:
- `PARALLEL_BUILDS=4` limits how many builds are *launched* concurrently (memory pressure: 4 concurrent builds × RAM/build)
- Jobserver limits total *compile jobs* running at any moment (CPU pressure: nproc tokens)

On a memory-constrained host (8G RAM), launching 20 builds at once would OOM even if compile jobs are throttled. `PARALLEL_BUILDS` remains the memory safety valve.

### build.sh fallback for standalone invocations

`lib/build.sh` is called directly for debugging single combos. Without a parent make's
jobserver, `MAKEFLAGS` has no `--jobserver-auth` → the fallback activates:
`-j = max(2, nproc/PARALLEL_BUILDS)` — same formula as before, zero behaviour change.

### Tier-0 / tier-1 flush barrier unchanged

The barrier is a correctness requirement: tier-1 configs borrow `.config-base` from
tier-0 siblings; if tier-0 is not done, the sibling cache miss causes a 29 s kconfig
rescan. The jobserver does not remove this need — it only improves utilisation within
each tier's straggler window.

### NO_JOBSERVER=1 escape hatch

Consistent with existing `NO_*` variables (`NO_PERF_BUILD`, `NO_CONFIG_CACHE`,
`NO_FETCH`). Set in `local.mk` for hosts where the jobserver causes unexpected behaviour
(e.g. make < 4.2, custom jobserver-incompatible toolchains).

### Named FIFO vs pipe FDs

Make ≥ 4.2: `--jobserver-auth=fifo:/path` — filesystem path, survives exec, no workaround needed.
Make < 4.2: `--jobserver-fds=R,W` — pipe FDs, closed by O_CLOEXEC across exec. Not supported.
Minimum make version check added to `make preflight`.

---

## Expected Acceleration

| Machine | `make full` current | With jobserver | Saved |
|---|---|---|---|
| Hetzner (8c, TCG) | ~85–125 min | ~65–100 min | ~15–25 min (~20%) |
| Laptop (16c, KVM) | ~25–44 min | ~21–38 min | ~4–6 min (~10–12%) |

Build phase only. Test phase (QEMU VMs) unaffected.

---

## Testing

```sh
make lint
make ci-test                           # includes test-jobserver.sh
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64   # verify no "jobserver unavailable" warning
make all NO_FETCH=1 CONFIGS="defconfig tinyconfig" ARCHS="x86_64 arm64"

# Verify straggler absorption — watch cores used by the last build:
watch -n2 'ps -ef | grep "bzImage" | grep -v grep | grep -o "build/[a-zA-Z0-9_-]*" | sort -u'

# Verify NO_JOBSERVER=1 fallback:
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64 NO_JOBSERVER=1
```
