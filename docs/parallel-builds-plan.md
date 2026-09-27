# Parallel Builds & Tests — Plan

Branch: `feat/parallel-builds`
Start date: 2026-09-27
Status: **implemented**

---

## Situation

All build, initramfs, and test loops in the Makefile ran sequentially. On a 16-core machine
with 4 architectures, three of the four cores sat idle during each kernel compilation. A full
`make extended` run took ~90 minutes wall time even though the work is embarrassingly parallel.
The infrastructure already isolates every combo in its own `build/<config>-<arch>/` directory —
the hard part was already done. Only the orchestration loops needed to change.

---

## Problems Solved

1. **Sequential loops** — `build`, `initramfs`, and `test` all used nested `for` loops with no
   concurrency; up to 20 combos ran one at a time.
2. **Oversubscription** — when running N builds in parallel, each used `-j$(nproc)`, flooding
   the system with `nproc × N` competing make jobs.
3. **Non-atomic `.config-base-commit` write** — `printf > file` created a 0-byte file before
   the write; a parallel sibling reader could get an empty commit hash.
4. **FIFO slot starvation** — `wait "${_pids[0]}"` blocked on the oldest job even when newer
   jobs finished earlier; on TCG-only hosts (no KVM) where riscv/arm64 finish in ~9s but
   x86_64 takes ~140s, this caused 130s of idle slots with PARALLEL_VMS=4.
5. **Inconsistent log format** — Makefile `@echo "[phase]..."` lines had no timestamp/elapsed,
   unlike the `HH:MM:SS [elapsed] config arch INFO` format from `lib/common.sh`.

---

## Goals

1. `PARALLEL_BUILDS=N` runs up to N kernel builds and N initramfs tasks simultaneously.
2. `PARALLEL_VMS=N` runs up to N QEMU VMs simultaneously.
3. Sibling config-cache correctness: tier-0 base configs (defconfig, tinyconfig, …) always
   finish before tier-1 dependents start, preserving cache hits.
4. `.config-base-commit` written atomically (tmp + mv) to prevent empty-file reads.
5. Per-build `-j` reduced proportionally (`nproc / PARALLEL_BUILDS`, floor 2) to avoid oversubscription.
6. Slots refill immediately when any job finishes (not just the oldest).
7. All Makefile orchestration lines use the same timestamp format as lib scripts.

---

## Scope

Files changed:
- `Makefile` — `PARALLEL_BUILDS`/`PARALLEL_VMS` variables (default 4) + exports; `build`,
  `initramfs`, `test` loops use `_enqueue`/`_flush` with `wait -n` sliding window; all
  `@echo "[phase]..."` replaced with `@lib/mklog.sh`; `_LOG_START` exported
- `lib/build.sh` — `info "Starting build"` at entry; `NPROC` from `nproc / PARALLEL_BUILDS`
  (floor 2); `_write_config_cache` writes atomically via tmp + mv
- `lib/mklog.sh` — new: thin wrapper that calls `common.sh`'s `log()` for Makefile lines;
  with no CONFIG/ARCH set, shows `-` in those columns
- `tests/ci/test-parallel-builds.sh` — new: 18 static checks verifying all structural changes
- `memory/workflows.md` — `PARALLEL_BUILDS` and `PARALLEL_VMS` in variable table

No changes to: `lib/vm.sh`, `lib/initramfs.sh`, `lib/report.sh`, `tests/custom/`, fetch scripts.

---

## Design Decisions

### Enqueue/flush pattern with wait -n sliding window

Each loop uses bash functions defined inline in the Make recipe:

```bash
_enqueue() {
    lib/build.sh "$1" "$2" &
    _pids+=("$!")
    while [[ ${#_pids[@]} -ge PARALLEL_BUILDS ]]; do
        wait -n || rc=1
        _new=(); for _p in "${_pids[@]}"; do
            kill -0 "$_p" 2>/dev/null && _new+=("$_p") || true
        done
        _pids=("${_new[@]}")
    done
}
_flush() { local _p; for _p in "${_pids[@]}"; do wait "$_p" || rc=1; done; _pids=(); }
```

`wait -n` (bash 4.3+, Ubuntu 22.04 = bash 5.1) waits for *any* child, then the `kill -0`
sweep removes the finished pid. This ensures a slot is freed the moment any job completes,
not just the oldest — critical on TCG hosts where arches have wildly different runtimes.

`_flush` drains sequentially (correct: all remaining jobs must finish before the phase ends).

### Tier ordering for sibling cache

The build loop splits into two passes separated by `_flush`:

**Tier 0** (base configs that produce a sibling `.config-base`):
`defconfig`, `tinyconfig`, `allnoconfig`, `allmodconfig`, `randconfig`

**Tier 1+** (all remaining configs that may read a sibling `.config-base`):
`kunitconfig`, `rand500config`, `randdefconfig`, `kunitrandconfig`, ns-variants, `vf2config`, etc.

`_flush` after tier 0 guarantees all base builds are complete before any tier-1 build starts,
so the sibling cache is always warm for tier-1 when tier-0 configs are in the same `CONFIGS` set.

### Atomic `.config-base-commit` write

```bash
# Before:
printf '%s\n' "$TREE_COMMIT" > "$_config_base_commit"

# After (atomic):
printf '%s\n' "$TREE_COMMIT" > "${_config_base_commit}.tmp" &&
  mv "${_config_base_commit}.tmp" "$_config_base_commit"
```

`mv` on the same filesystem is `rename(2)` — the file is either absent or fully written.

### Consistent log format via lib/mklog.sh

```bash
#!/bin/bash
set -euo pipefail
. "$(dirname "$0")/common.sh"
log "$*"
```

`_LOG_START` is exported by the Makefile (set once at parse time) so all subprocess elapsed
times are relative to `make` start, not each script's own start.

### Default parallelism

Both `PARALLEL_BUILDS` and `PARALLEL_VMS` default to `4`. Validated on:
- Local laptop (16-core, KVM): `make all` with 4 configs × 4 arches in 1m29s
- Hetzner (8-core, no KVM): same run in 14m24s, all 16 slots filled optimally

Lower to `2` in `local.mk` on machines with <8 cores or <8G RAM.

---

## Known Limitation: Straggler Tax

`-j$NPROC` is computed once at `lib/build.sh` launch time (`nproc/PARALLEL_BUILDS`, floor 2)
and cannot change mid-build. At the end of each tier the last surviving build holds its
original reduced `-j` while the other slots are empty:

```
Hetzner (8 cores, PARALLEL_BUILDS=4):
  tier-0 full:  4 builds × -j2 = 8 jobs  (fully utilised)
  tier-0 end:   1 build  × -j2 = 2 jobs  (6 cores idle)

Laptop (16 cores, PARALLEL_BUILDS=4):
  tier-0 full:  4 builds × -j4 = 16 jobs  (fully utilised)
  tier-0 end:   1 build  × -j4 =  4 jobs  (12 cores idle)
```

**Root cause:** each `build.sh` invocation passes an explicit `-jN` to the kernel `make`,
which disconnects it from the GNU make jobserver and creates a private N-slot pool.

**Fix (planned `feat/jobserver-builds`):** restructure build targets so the harness
`make -j$(nproc)` owns the token pool; `build.sh` calls the kernel `make` without `-j`
so it inherits the shared jobserver pipe via `MAKEFLAGS`. Stragglers then absorb freed
tokens automatically. Estimated savings: Hetzner ~15–20 min/run (~20%), laptop ~4–6 min/run (~10%).

---

## Testing

```sh
make dev-test
make lint
make ci-test

# Build slot monitor:
watch -n2 'printf "BUILD:\n"; ps -ef | grep "timeout.*bzImage" | grep -v grep | grep -o "build/[a-zA-Z0-9_-]*" | sort -u | sed "s/^/  /"; printf "TEST:\n"; ps -ef | grep qemu-system | grep -v grep | grep -o "build/[a-zA-Z0-9_-]*" | grep -v initramfs | sort -u | sed "s/^/  /"'
```
