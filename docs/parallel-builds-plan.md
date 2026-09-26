# Parallel Builds & Tests — Plan

Branch: `feat/parallel-builds`
Start date: 2026-09-27

---

## Situation

All build, initramfs, and test loops in the Makefile run sequentially. On a 16-core machine
with 4 architectures, three of the four cores sit idle during each kernel compilation. A full
`make extended` run takes ~90 minutes wall time even though the work is embarrassingly parallel.
The infrastructure already isolates every combo in its own `build/<config>-<arch>/` directory —
the hard part is already done. Only the orchestration loops need to change.

---

## Problems to Solve

1. **Sequential loops** — `build`, `initramfs`, and `test` all use nested `for` loops with no
   concurrency; up to 20 combos run one at a time.
2. **Oversubscription** — when running N builds in parallel, each uses `-j$(nproc)`, flooding
   the system with `nproc × N` competing make jobs.
3. **Non-atomic `.config-base-commit` write** — `printf > file` creates a 0-byte file before
   the write; a parallel sibling reader could get an empty commit hash, causing a cache miss
   rather than a hit (benign but wasteful).

---

## Goals

1. `PARALLEL_BUILDS=1` (default) produces byte-for-byte identical behavior to the current code.
2. `PARALLEL_BUILDS=N` runs up to N kernel builds and N initramfs tasks simultaneously.
3. `PARALLEL_VMS=N` runs up to N QEMU VMs simultaneously.
4. Sibling config-cache correctness: tier-0 base configs (defconfig, tinyconfig, …) always
   finish before tier-1 dependents start, preserving cache hits.
5. `.config-base-commit` written atomically (tmp + mv) to prevent empty-file reads.
6. Per-build `-j` reduced proportionally (`nproc / PARALLEL_BUILDS`) to avoid oversubscription.

---

## Scope

Files changed:
- `Makefile` — add `PARALLEL_BUILDS`/`PARALLEL_VMS` variables + exports; replace `build`,
  `initramfs`, and `test` loop bodies with `_enqueue`/`_flush` background-job pattern;
  update help text
- `lib/build.sh` — compute `NPROC` from `nproc / PARALLEL_BUILDS` (floor 1); make
  `_write_config_cache` write atomically via tmp + mv
- `tests/ci/test-parallel-builds.sh` — new: static verification of all changes
- `memory/workflows.md` — add `PARALLEL_BUILDS` and `PARALLEL_VMS` to variable table

No changes to: `lib/vm.sh`, `lib/initramfs.sh`, `lib/report.sh`, any test scripts in
`tests/custom/`, fetch scripts.

---

## Non-goals

- Automatic optimal parallelism detection (user sets the cap explicitly).
- Parallelising `make extended` across `full` and `ns-full` sub-makes (they already use the
  rc-accumulator pattern and run sequentially at the sub-make level).
- Changing QEMU memory allocation (VM RAM is unchanged; PARALLEL_VMS is the user's safety knob).

---

## Design Decisions

### Enqueue/flush pattern with sliding window

Each loop uses two bash functions defined inline in the Make recipe:

```bash
_enqueue() {
    lib/build.sh "$1" "$2" &
    _pids+=("$!")
    # drain oldest job once we're at cap
    while [[ ${#_pids[@]} -ge PARALLEL_BUILDS ]]; do
        wait "${_pids[0]}" || rc=1
        _pids=("${_pids[@]:1}")
    done
}
_flush() { for _p in "${_pids[@]}"; do wait "$_p" || rc=1; done; _pids=(); }
```

When `PARALLEL_BUILDS=1`: `_enqueue` starts job in background and immediately waits (len=1 ≥ 1).
Functionally sequential — no behavioral difference from the old loop.

When `PARALLEL_BUILDS=N>1`: up to N jobs run concurrently; each enqueue drains the oldest
finished job once the window is full.

### Tier ordering for sibling cache

The build loop splits into two passes separated by `_flush`:

**Tier 0** (base configs that may produce a sibling `.config-base`):
`defconfig`, `tinyconfig`, `allnoconfig`, `allmodconfig`, `randconfig`

**Tier 1+** (all remaining configs that may read a sibling `.config-base`):
`kunitconfig`, `rand500config`, `randdefconfig`, `kunitrandconfig`, ns-variants, `vf2config`, etc.

`_flush` after tier 0 guarantees all base builds are complete before any tier-1 build starts,
so the sibling cache is always warm for tier-1 when tier-0 configs are in the same `CONFIGS` set.
If tier-0 configs are not in `CONFIGS`, tier-0 is empty and tier-1 gets no sibling benefit —
same as today (graceful miss, falls back to `kmake`).

### PARALLEL_BUILDS=1 for initramfs and test

`initramfs` and `test` loops use `PARALLEL_BUILDS` and `PARALLEL_VMS` respectively. At
`=1`, both are sequential. initramfs has no sibling dependencies so no tier split is needed.

### Atomic `.config-base-commit` write

```bash
# Before:
printf '%s\n' "$TREE_COMMIT" > "$_config_base_commit"

# After (atomic):
printf '%s\n' "$TREE_COMMIT" > "${_config_base_commit}.tmp" &&
  mv "${_config_base_commit}.tmp" "$_config_base_commit"
```

`mv` on the same filesystem is `rename(2)` — the file is either absent or fully written.
Eliminates the 0-byte window between `O_CREAT` and the completed write.

---

## Testing Strategy

- **Static analysis** — `test-parallel-builds.sh` greps Makefile and lib/build.sh to verify
  each code change is present
- **Tier ordering** — grep verifies tier-0 `_flush` appears before tier-1 loop in Makefile
- **PARALLEL_BUILDS=1 integration** — `make build NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64`
  still passes with default `PARALLEL_BUILDS=1` (validated by existing `make dev-test`)
- **No VM/kernel tests** — parallel execution with multiple kernels requires a kernel tree and
  is out of scope for Tier 2 CI

---

## Testing Commands

```sh
make dev-test
# Expected: exit 0, ≥70% decision paths covered within time budget

make lint
# Expected: shellcheck clean, context size checks pass

make ci-test
# Expected: test-parallel-builds.sh all pass; all other tests unaffected

make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64 PARALLEL_BUILDS=1
# Expected: exact same behavior as before this branch

make all NO_FETCH=1 CONFIGS="defconfig tinyconfig kunitconfig" ARCHS="x86_64" PARALLEL_BUILDS=4
# Expected: defconfig+tinyconfig build first (tier 0), then kunitconfig (tier 1); NPROC reduced
```
