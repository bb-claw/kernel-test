# Config Cache — Plan

Branch: `feat/config-cache`
Start date: 2026-09-26

---

## Situation

The `make tinyconfig` kernel target runs the kconfig `conf` tool 3–4 times in sequence
(allnoconfig → merge tiny.config → arch overlay → olddefconfig), each pass scanning the
entire Kconfig symbol tree for the target arch. On a quiet laptop this takes 29 s for
riscv; defconfig takes 5 s (single `conf` pass). The output is fully deterministic for
a given kernel commit and config fragment set — the same `.config` SHA256 is produced
every run. In a parallel build (Group 3 work), the tinyconfig/riscv config phase
becomes the critical path (29 s vs. 7 s arm64 build), so reducing it matters.

---

## Problems to Solve

1. **Redundant kconfig parsing** — `make tinyconfig ARCH=riscv` parses the full Kconfig
   tree 3–4 times per run (29 s) even when nothing has changed.
2. **rand500config pays the same cost** — it calls `kmake tinyconfig` internally as its
   base; with no cross-combo sharing it also pays 29 s every run.

---

## Goals

1. Config phase for deterministic configs ≤ 5 s on cache hit (down from 5–35 s).
2. rand500config reuses the tinyconfig base cache from a sibling combo if valid, saving
   another 29 s.
3. Cache is auto-invalidated on kernel commit change or fragment file change.
4. `NO_CONFIG_CACHE=1` forces a fresh regen unconditionally.
5. CI test verifies: miss writes stamp, hit skips kmake, invalidation triggers regen,
   `NO_CONFIG_CACHE=1` bypasses cache.

---

## Scope

Files changed:
- `lib/common.sh` — add `config_cache_hash()` and `config_cache_valid()` helpers
- `lib/build.sh` — add cache check/write around the `kmake <base-config>` step for all
  deterministic configs; add cross-combo tinyconfig base reuse inside rand500config path
- `Makefile` — export `NO_CONFIG_CACHE` variable (default `0`)
- `tests/ci/test-config-cache.sh` — new CI test
- `memory/workflows.md` — document `NO_CONFIG_CACHE` in the variables table

No changes to: `lib/initramfs.sh`, `lib/vm.sh`, `lib/report.sh`, `configs/`, or any
test scripts.

---

## Non-goals

- Caching the fragment application step or `olddefconfig` — these are fast (≤ 6 s) and
  depend on user-editable fragment files; not worth the complexity.
- Caching rand500config or randdefconfig configs — intentionally random; the randomness
  is the point.
- Sharing the cache between the `kernel-test` and `kernel-test-stable-rc` clones — each
  clone has its own `build/` dir; cross-clone sharing adds path complexity for marginal
  benefit.

---

## Design decisions

### Cache key

`sha256(TREE_COMMIT + sha256(fragment) + sha256(arch_overlay) + sha256(namespaces.config))`

All fragment files that do not exist are silently omitted from the hash (only ns-variant
configs include namespaces.config). This is a single opaque hash — easy to compare,
impossible to forge accidentally.

Alternatives rejected:
- Kernel commit only: misses fragment changes during harness development.
- Including Kconfig file mtimes: correct but scanning the tree adds ~1 s overhead and
  is complex to implement portably.

### Cache storage — two files per combo

```
build/<config>-<arch>/.config-base         # pre-fragment .config snapshot
build/<config>-<arch>/.config-base-commit  # plain kernel commit hash for cross-combo lookup
build/<config>-<arch>/.config-cache-hash   # full cache key (single sha256 line)
```

`.config-base` stores the output of `kmake <base-config>` before any fragment is
applied. This is what rand500config needs (it appends 500 random options to this base).

`.config-base-commit` stores just the kernel commit hash. Used by rand500config to
validate the tinyconfig sibling cache without needing to recompute the tinyconfig
fragment hash.

`.config-cache-hash` stores the full key. A match means both the kernel version and all
fragments are unchanged → safe to restore `.config-base` and skip to fragment application.

### rand500config cross-combo reuse

rand500config checks `build/tinyconfig-$ARCH/.config-base-commit`. If it matches
`$TREE_COMMIT` and `build/tinyconfig-$ARCH/.config-base` exists, it copies that file
instead of running `kmake tinyconfig`. Result: rand500config config phase drops from
~37 s to ~8 s (just the randconfig temp dir step, which must run because it is random).

### NO_CONFIG_CACHE=1 semantics

Skips the cache check and runs a fresh `kmake <base-config>`. The new output is still
written to the cache files so subsequent runs benefit. Mirrors `CCACHE_RECACHE=1`
semantics.

### Deterministic configs that get caching

`tinyconfig`, `defconfig`, `allnoconfig`, `kunitconfig`, `allmodconfig`, `vf2config`,
and their ns-variants (`tinynsconfig`, `defnsconfig`, `kunitnsconfig`,
`kunitrandnsconfig`, `rand500nsconfig`, `randdefnsconfig`). The ns-variants include
`configs/namespaces.config` in the fragment hash.

Not cached: `rand500config`, `randdefconfig`, `randconfig`, `kunitrandconfig`,
`localconfig` (random or running-kernel-dependent).

---

## Testing strategy

- **Cache miss path** — verify `.config-base`, `.config-base-commit`, `.config-cache-hash`
  are written after a config step with a fake kernel tree stub.
- **Cache hit path** — verify `kmake` is not called on the second run (stub Makefile
  exits non-zero to detect any invocation).
- **Invalidation on commit change** — modify `.config-base-commit` to a wrong hash;
  verify fresh regen.
- **Invalidation on fragment change** — append a comment to a fragment file; verify
  `.config-cache-hash` no longer matches.
- **NO_CONFIG_CACHE=1** — verify cache is bypassed and new cache is written afterwards.
- **rand500config cross-combo** — pre-populate a valid tinyconfig base cache; verify
  rand500config skips `kmake tinyconfig`.
- **Shellcheck** — `shellcheck --severity=warning` on `lib/build.sh`, `lib/common.sh`,
  and `tests/ci/test-config-cache.sh`.

---

## Testing commands

```sh
# Always run before pushing any branch
make dev-test
# Expected: exit 0, ≥70% decision paths covered

# Tier 2 CI
make ci-test
# Expected: all tests pass including test-config-cache.sh

# Isolated cache test
bash tests/ci/test-config-cache.sh
# Expected: all assertions pass, 0 failed

# Verify config time improvement (quiet system)
time make build NO_FETCH=1 CONFIGS=tinyconfig ARCHS=riscv  # first run (miss)
time make build NO_FETCH=1 CONFIGS=tinyconfig ARCHS=riscv  # second run (hit)
# Expected: second run config phase ~5 s vs ~29 s first run

# Verify rand500config reuses tinyconfig base
make build NO_FETCH=1 CONFIGS=tinyconfig ARCHS=riscv
time make build NO_FETCH=1 CONFIGS=rand500config ARCHS=riscv
# Expected: rand500config config phase ~8 s (skips kmake tinyconfig)

# Verify NO_CONFIG_CACHE=1 forces regen
time make build NO_FETCH=1 CONFIGS=tinyconfig ARCHS=riscv NO_CONFIG_CACHE=1
# Expected: full 29 s config regen; cache files updated
```
