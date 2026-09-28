# Shared ccache — Plan

Branch: `feat/ccache-share`
Start date: 2026-09-27

---

## Situation

Each kernel-test clone (`kernel-test`, `kernel-test-stable`, `kernel-test-stable-rc`) keeps its
own `cache/` directory for ccache, each capped at 25 G. The three caches are independent: warming
mainline has zero effect on a subsequent stable-rc build even when the two kernel trees share most
source files. A single 75 G shared cache eliminates eviction pressure and — via per-build
`CCACHE_BASEDIR=$KERNEL_TREE` normalization — enables cross-tree object reuse when source content
is identical across trees.

---

## Problems to Solve

1. **No cross-tree reuse** — each clone discards the other clones' cached objects; first build of
   stable-rc after mainline is always cold even when 70–85 % of source files are identical.
2. **Separate 25 G budgets** — each clone's cache evicts independently; a localconfig build
   (~4.6 G output) can evict half the tinyconfig objects in the same clone.
3. **base_dir set to $HOME** — normalizes paths only relative to the home dir; two trees at
   `~/git/linux` and `~/git/linux-stable` still produce different cache keys for identical files.

---

## Goals

1. Auto-detect `~/git/kernel-test-ccache/` at Makefile parse time; use it when present, fall back
   silently to `cache/` when absent. Zero config for the standard multi-clone setup.
2. `make ccache-init` creates and configures the shared dir (75 G, sloppiness, base_dir for
   standalone use). Idempotent.
3. Per-build `CCACHE_BASEDIR=$KERNEL_TREE` (env var, not ccache.conf) enables cross-tree cache
   hits when source content and normalized flags match.
4. `make preflight` reports the active ccache dir (shared vs local) as an INFO line.
5. CI gate: `tests/ci/test-ccache-share.sh` covers auto-detect logic and init idempotency.

---

## Scope

Files/components changed:
- `Makefile` — CCACHE_DIR auto-detect block; export CCACHE_DIR; fix `.ccache-stats-before` line;
  `ccache-init` and `ccache-status` targets
- `lib/build.sh` — conditional CCACHE_DIR (use Makefile-exported value if set); replace
  `ccache --set-config base_dir=$HOME` with `export CCACHE_BASEDIR=$KERNEL_TREE`
- `lib/preflight.sh` — add CCACHE_DIR variable; update space check; add INFO line
- `tests/ci/test-ccache-share.sh` — new; 4 tests (CC1–CC4)
- `tests/ci/coverage-map.md` — add K-ccache group; 48 → 52 paths
- `scripts/dev-test.sh` — add CC1–CC4 to ci9_tests[]; total_paths 48 → 52
- `memory/project.md` — update ccache Key Decision row

No changes to: `lib/monitor.sh` (already reads CCACHE_DIR from env), `lib/metrics.sh`,
any test scripts, `local.mk` (no changes needed — zero-config goal).

---

## Non-goals

- Cache migration from existing clone `cache/` dirs (one-time manual rsync by user).
- Automatically sharing caches across different machines or users.
- Changing `CCACHE_MAX_SIZE` for users who do NOT have the shared dir (stays 25 G).

---

## Design decisions

### Why CCACHE_BASEDIR=$KERNEL_TREE and not base_dir=$(dirname KERNEL_TREE)

ccache normalizes all absolute paths in the preprocessed output and command-line flags that share
the `base_dir` prefix. kbuild passes absolute `-I$(srctree)/include` flags where `srctree` is the
kernel source tree. Two trees (`~/git/linux`, `~/git/linux-stable`) differ only in the final
directory component.

- `base_dir=~/git/` (parent) → `-I./linux/include` vs `-I./linux-stable/include` — still different
- `base_dir=~/git/linux` (the tree itself) → `-I./include` for mainline builds; same for stable when
  `base_dir=~/git/linux-stable` is set per that build → both normalize to `-I./include` → **hit**

Setting `CCACHE_BASEDIR=$KERNEL_TREE` as an **environment variable** (not in ccache.conf) is the
correct mechanism: it is per-build, overrides ccache.conf, and each clone sets it to its own tree
path before compilation. The ccache.conf `base_dir` written by `make ccache-init` is set to
`$(dir KERNEL_TREE)` (the parent directory) for the benefit of standalone `ccache` invocations
only; it does not affect build-time normalization.

### Why env var overrides ccache.conf for base_dir

`ccache.conf` is shared between all three clones when using the shared dir. Writing a tree-specific
absolute path into it would be overwritten by whichever clone ran last, and parallel builds would
race on the file. The env var `CCACHE_BASEDIR` is process-local, set by `build.sh` for the
duration of each compiler invocation, and never touches the shared ccache.conf.

### Silent fallback vs warn on absent shared dir

Fresh clones and CI runners do not have `~/git/kernel-test-ccache/`. A warning on every build would
be noise. Silent fallback to `cache/` is the right default; `make preflight` shows which cache is
active so the user can see the state without the warning appearing on every build.

### `make ccache-init` as dedicated target (not in bootstrap)

`make bootstrap` is run once per machine and installs system packages. ccache-init is idempotent
and safe to re-run after resizing or migrating. Keeping it separate avoids making bootstrap heavier
and allows users to run it standalone without re-running the full bootstrap.

---

## CI paths

| ID  | Description | Test |
|-----|-------------|------|
| CC1 | shared dir present → CCACHE_DIR resolves to shared path | test-ccache-share.sh |
| CC2 | shared dir absent → CCACHE_DIR falls back to local cache/ | test-ccache-share.sh |
| CC3 | ccache-init is idempotent (run twice → same result) | test-ccache-share.sh |
| CC4 | ccache.conf after init contains max_size=75G and base_dir | test-ccache-share.sh |

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, ≥70 % paths covered

bash tests/ci/test-ccache-share.sh
# Expected: 4 passed, 0 failed

make -s ccache-status
# Expected: CCACHE_DIR=~/git/kernel-test-ccache (if shared dir exists)
# or:       CCACHE_DIR=<repo>/cache (local fallback)

make ccache-init
# Expected: shared dir created/confirmed, ccache.conf written, stats zeroed

make preflight NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64 2>&1 | grep ccache
# Expected: INFO line showing active CCACHE_DIR and (shared) or (local)

make all NO_FETCH=1 CONFIGS=tinyconfig
# Expected: builds pass; CCACHE section in make monitor shows shared cache stats
```
