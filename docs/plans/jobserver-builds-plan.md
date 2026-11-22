# GNU Make Jobserver Builds — Plan

Branch: `feat/jobserver-builds`
Prerequisite: `feat/parallel-builds` merged to `main`
Status: **planned**

---

## Situation

`feat/parallel-builds` introduced `PARALLEL_BUILDS=4` with per-build
`-j = nproc/PARALLEL_BUILDS` (floor 2). This eliminates the old sequential bottleneck
but creates a **straggler tax**: at the end of each tier the last surviving build holds
a reduced `-j` while the other slots are empty.

On Hetzner (8 cores, TCG): defconfig-i386 runs ~340 s at -j2 while 6 cores sit idle.
On laptop (16 cores, KVM): last build at -j4 while 12 cores sit idle.

---

## Problem

Each `lib/build.sh` invocation passes an explicit `-jN` to the kernel `make`:

```bash
make -C "$KERNEL_TREE" -j"$NPROC" bzImage
```

An explicit `-jN` **disconnects** from the GNU make jobserver — the child make creates
its own private N-slot pool instead of participating in the parent's shared pool.
Freed tokens from finished siblings never reach the straggler.

---

## Solution: GNU Make Jobserver

The jobserver is a Unix pipe holding `nproc` tokens. Before spawning any compile job,
make must `read()` one token; on completion it `write()`s it back. An empty pipe blocks
until a token is returned. Child makes without an explicit `-jN` inherit the pipe FDs
via `MAKEFLAGS --jobserver-auth=R,W` and draw from the same pool.

When 3 of 4 builds finish, their tokens return to the pipe. The straggler's make reads
them immediately and spawns additional compile jobs — up to the full `nproc` limit.

**Prerequisite check before implementing:**

```bash
# Verify jobserver FDs survive a shell script exec boundary
make -j4 -f /dev/stdin <<'EOF'
all:
	@bash -c 'echo "MAKEFLAGS=$$MAKEFLAGS"'
	@bash -c 'make --version > /dev/null; echo "exit: $$?"'
EOF
```

If the inner shell shows a live `--jobserver-auth=` and the inner `make` exits 0 without
a "jobserver unavailable" warning, the approach works. If not, the pipe FDs are
`O_CLOEXEC`-closed across the `exec()` boundary and an alternative is needed (explicit
FD passing or a named POSIX semaphore).

---

## Goals

1. Straggler builds automatically absorb freed tokens up to `nproc`.
2. No regression on full-load phases (all slots busy) — jobserver is transparent there.
3. `PARALLEL_BUILDS` and `PARALLEL_VMS` remain as caps (max concurrent jobs launched),
   separate from the per-job `-j` which is now dynamic.
4. Fallback path if jobserver FDs are not inherited: warn + keep current static `-j`.

---

## Scope

Files to change:

- `Makefile` — build loop uses make targets (`build-$config-$arch`) rather than shell
  background jobs; top-level `$(MAKE) -j$(nproc) $(BUILD_TARGETS)` owns the token pool;
  keep `PARALLEL_BUILDS` as the parallel-launch cap (separate concern from `-j`)
- `lib/build.sh` — drop explicit `-j$NPROC` from kernel `make` invocation; detect
  whether jobserver is live (check `MAKEFLAGS` for `--jobserver-auth`); fall back to
  `-j$(nproc)` if not (standalone `lib/build.sh` invocations must still work)
- `tests/ci/test-jobserver.sh` — static checks: no explicit `-j` in kernel make call
  inside build.sh; make targets present in Makefile
- `docs/jobserver-builds-plan.md` — this file

---

## Design Decisions

### Separation of concerns

`PARALLEL_BUILDS` controls **how many builds are launched concurrently** (queue depth).
The jobserver controls **how many compile jobs run within each build** (token pool).
They are orthogonal: PARALLEL_BUILDS=4 with jobserver means 4 concurrent builds all
sharing one nproc-sized token pool.

### Fallback for standalone build.sh

`lib/build.sh` is also called directly (e.g. `make all CONFIGS=tinyconfig ARCHS=x86_64`
which ends up as a single build outside of any parallel context). In that case
`MAKEFLAGS` has no `--jobserver-auth` and omitting `-j` would give `-j1`. The script
must detect this and supply `-j$(nproc)` as a fallback:

```bash
if [[ "$MAKEFLAGS" == *--jobserver-auth* ]]; then
    NPROC_ARG=""          # inherit from jobserver
else
    NPROC_ARG="-j$(nproc)"
fi
make -C "$KERNEL_TREE" $NPROC_ARG bzImage
```

### Tier ordering unchanged

The `_flush` barrier between tier-0 and tier-1 is a correctness requirement (sibling
config cache). The jobserver does not change this — tier-0 still fully drains before
tier-1 starts. The benefit is that within a tier, the last straggler uses more cores.

---

## Expected Acceleration

| Machine | `make full` current | With jobserver | Saved |
|---|---|---|---|
| Hetzner (8c, TCG) | ~85–125 min | ~65–100 min | ~15–25 min (~20%) |
| Laptop (16c, KVM) | ~25–44 min | ~21–38 min | ~4–6 min (~10–12%) |

Savings apply to build phase only. Test phase (QEMU VMs) is unaffected.
Benefit is second-order relative to `feat/parallel-builds` (which saved ~3h 15m–35m).

---

## Testing

```sh
make dev-test
make lint
make ci-test
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64
# verify no "jobserver unavailable" warning in output
make all NO_FETCH=1 CONFIGS="defconfig tinyconfig" ARCHS="x86_64 arm64"
# watch straggler utilisation:
watch -n2 'ps -ef | grep "bzImage" | grep -v grep | grep -o "build/[a-zA-Z0-9_-]*" | sort -u'
```
