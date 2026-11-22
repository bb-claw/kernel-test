# ccache improvements — Plan

Branch: `feat/ccache-improvements`
Start date: 2026-09-25

---

## Situation

All kernel-test clones share a default ccache max size of 5 GiB. A full localconfig
build (Manjaro desktop config) produces ~4.6 GiB of object files; at 5 GiB ccache
capacity and 2:1 compression the cache fills in a single build and triggers 12 000+
eviction cleanups, causing 82% cache miss rate and 30-minute `make install` runs.
The `CCACHE_SLOPPINESS`, `CCACHE_COMPRESSLEVEL`, and `CCACHE_BASEDIR` settings are
also left at their defaults, leaving additional hit-rate improvement on the table.

---

## Problems to Solve

1. **Cache thrashing** — 5 GiB default causes localconfig to evict CI build objects
   (tinyconfig/defconfig/arm64/riscv) on every `make install` run; 82.51% miss rate
   across 1.5 M cacheable calls; 12 191 eviction cleanups observed.
2. **`__DATE__`/`__TIME__` invalidation** — kernel uses these macros in a handful of
   headers; any rebuild that changes clock time creates new preprocessed hashes and
   forces a miss on otherwise-identical object files.
3. **High compression level** — default zstd level 6 slows cache reads/writes
   unnecessarily on NVMe; level 1 gives similar size with significantly lower latency.
4. **Absolute paths in cache keys** — without `CCACHE_BASEDIR`, embedded absolute source
   paths in debug info prevent cache reuse if the tree is ever relocated or symlinked.

---

## Goals

1. `CCACHE_MAX_SIZE=25G` default — one shared cache per clone holds localconfig +
   all CI (config × arch) combinations without thrashing.
2. `CCACHE_TUNE=1` default — persists `sloppiness=time_macros`, `compression_level=1`,
   `base_dir=$HOME`, and `hard_link=true` to `ccache.conf` via `--set-config`.
3. `CCACHE_TUNE=0` mode — "size only": only the max_size change, no behaviour tuning;
   resets tuning settings to defaults.
4. Both variables overridable in `local.mk` per-machine.
5. CI test (`test-ccache-config.sh`) verifies defaults, `--set-config` persistence,
   conditional tuning, and TUNE=0 reset in build.sh and install.sh.

---

## Scope

Files/components changed:
- `Makefile` — add `CCACHE_MAX_SIZE ?= 25G` and `CCACHE_TUNE ?= 1`; export both
- `lib/build.sh` — export `CCACHE_MAXSIZE`, conditionally export sloppiness/compress/basedir
- `lib/install.sh` — same as build.sh (install rebuilds modules via ccache)
- `tests/ci/test-ccache-config.sh` — new CI test (assertions on defaults + behaviour)
- `memory/workflows.md` — document new variables

No changes to: ccache.conf files, CACHE_DIR path, `make clean` (already wipes cache/),
bootstrap.sh (ccache already installed), any other lib script.

---

## Non-goals

- Shared central cache across clones — per-clone isolation avoids concurrent build
  contention; complexity not justified.
- Separate cache-local/ for localconfig — one 25G shared cache is simpler and
  sufficient; split caches add Makefile complexity for marginal benefit.
- Raising compression level for slower machines — level 1 is always faster on NVMe;
  users on spinning disks can override with `CCACHE_TUNE=0`.
- `make ccache-config` target — env-var approach is cleaner: settings apply consistently
  on every build without a separate setup step; no ccache.conf to manage.

---

## Design decisions

### `--set-config` to persist all settings, not environment variables

All settings are written to `$CCACHE_DIR/ccache.conf` via `ccache --set-config` at
the start of every `lib/build.sh` and `lib/install.sh` invocation. This means
settings are visible to standalone `ccache --show-config`/`--show-stats` commands,
and external invocations (e.g. `make olddefconfig` configure steps) honour the same
tuning. Environment variables would only apply within our scripts and leave the
config file showing stale defaults — causing confusion and allowing external
invocations to evict down to the 5G default. No separate `make ccache-config` step
required; settings are applied idempotently on every build. Users override per-machine
via `local.mk` (`CCACHE_MAX_SIZE`, `CCACHE_TUNE`).

### 25G default, not 15G or 20G

`4.6 GiB` of build output at ~2:1 zstd compression ≈ 2.3 GiB per build. A complete
`make all` across 4 archs and 9 configs produces additional objects. 25G gives
comfortable headroom for two full localconfig builds (current + previous kernel
version) plus all CI combos without eviction. Users on constrained machines can
set `CCACHE_MAX_SIZE=10G` in `local.mk`.

### CCACHE_TUNE=0 as explicit "size only" mode

Users debugging cache correctness issues (e.g., suspected stale cache serving wrong
objects) need a way to disable all behavioural changes without also shrinking the
cache. `CCACHE_TUNE=0` disables sloppiness/compress/basedir while keeping the 25G
limit, making it easy to bisect whether a tuning option caused a problem.

### time_macros sloppiness

The kernel uses `__DATE__`/`__TIME__` in `init/version.c` (linux_banner string) and
a handful of other files. With `time_macros`, ccache ignores these macros when
computing the cache key. The cached object will have a stale build timestamp in
`uname -a` output. This is acceptable for a test harness — we test functionality,
not build metadata. Production distro kernels should not use this flag.

### Compression level 1

zstd level 1 trades ~5-10% larger cache entries for significantly faster read/write
on NVMe (the dominant storage for modern development machines). At level 1 the cache
stays well within 25G for typical workloads; the size difference is not material.

---

## Testing strategy

- **`test-ccache-config.sh`** — static assertions on Makefile defaults, export lines,
  and build.sh/install.sh conditional logic; no kernel build required
- **Manual** — observe ccache hit rate after one warm build: `CCACHE_DIR=cache ccache --show-stats`
- **Existing CI** — `make dev-test` and `make ci-test` cover build pipeline; no change
  to build logic, so no new integration test needed

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, ≥70% decision paths

make ci-test
# Expected: all tests pass including test-ccache-config.sh

# Verify variables are present in Makefile
grep 'CCACHE_MAX_SIZE\|CCACHE_TUNE' Makefile
# Expected: two ?= lines + export line

# After one full build, confirm hit rate improved
CCACHE_DIR=cache ccache --show-stats | grep -E 'hit|miss|size'
# Expected: hit rate > 80% on second identical build
```
