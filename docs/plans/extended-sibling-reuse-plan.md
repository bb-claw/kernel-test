# Extended Sibling Reuse — Plan

Branch: `feat/extended-sibling-reuse`
Start date: 2026-09-26

---

## Situation

The config cache (feat/config-cache, PR #82) saves the pre-fragment `.config-base`
per `(config, arch)` combo and reuses it on subsequent runs. It also has explicit
sibling reuse for three random configs (rand500config, randdefconfig, kunitrandconfig)
so they can borrow the tinyconfig/defconfig base from a sibling combo rather than
re-running an expensive `kmake` on the first cold run.

Five deterministic configs — `kunitconfig`, `tinynsconfig`, `defnsconfig`,
`kunitnsconfig`, and `vf2config` — share a base with an already-built sibling but
have no sibling lookup. On a cold run of `make extended`, each pays its own full
`kmake` cost even though the output is identical to the sibling's.

---

## Problems to Solve

1. **Redundant `kmake` on cold runs** — `kunitconfig` runs `kmake defconfig` even
   when `defconfig-$ARCH/.config-base` already exists from the same run. Same for
   `tinynsconfig`/`defnsconfig`/`kunitnsconfig` and their respective base siblings.
   On laptop this wastes ~270 s per cold run of `make extended`; on Hetzner ~114 s.

2. **Makefile ordering doesn't front-load base configs** — `make full` currently
   starts with `kunitconfig`, before `defconfig` or `tinyconfig` have run, so any
   sibling reuse within the same `make full` call would not fire even after the code
   change. Same for `make ns-full`.

3. **Inline sibling check copy-pasted three times** — the commit-hash check and
   `.config-base` copy in rand500config/randdefconfig/kunitrandconfig blocks is
   duplicated, making it error-prone to extend or modify.

---

## Goals

1. Extract `_try_sibling_base <dir>` helper used by all sibling lookup sites.
2. Add sibling reuse for `kunitconfig` (+ `kunitnsconfig`), `tinynsconfig`,
   `defnsconfig`, and `vf2config`.
3. Deterministic configs write their own per-combo cache after a sibling hit so
   that subsequent runs use the per-combo cache and never consult the sibling again.
4. Reorder `make smoke/full/ns-smoke/ns-full` so base configs run first.
5. New test file `tests/ci/test-sibling-reuse.sh` covering all new cases and the
   key correctness invariant.

---

## Scope

Files/components changed:
- `lib/build.sh` — add `_try_sibling_base`, refactor existing 3 inline blocks,
  add sibling reuse for kunitconfig, tinynsconfig, defnsconfig, vf2config
- `Makefile` — reorder CONFIGS strings for smoke/full/ns-smoke/ns-full
- `tests/ci/test-sibling-reuse.sh` — new test file (unit + integration)
- `memory/project.md` — update Key Decisions sibling reuse note
- `memory/config-profiles.md` — update cache note to reflect new siblings

No changes to: `lib/common.sh` (config_cache_hash/config_cache_valid unchanged),
`tests/ci/test-config-cache.sh` (existing tests unaffected), report/vm pipeline.

---

## Non-goals

- Sharing a single on-disk base file across combos (current design: each combo
  still writes its own `.config-base`; sibling reuse only skips the `kmake` step
  by copying from an already-written sibling).
- Parallelising builds (out of scope; sequential iteration unchanged).
- Sibling reuse for `allnoconfig`, `allmodconfig` — each is its own unique base
  target with no other combo sharing it.

---

## Design decisions

### `_try_sibling_base <dir>` — pure lookup, caller writes cache

```bash
# Returns 0 and copies <dir>/.config-base to $OUT_DIR/.config on a valid hit.
# Returns 1 on any miss (NO_CONFIG_CACHE=1, missing file, commit mismatch).
# Does NOT write the caller's own cache — the caller is responsible:
#   deterministic configs: call _write_config_cache after a 0 return
#   random configs: do NOT call _write_config_cache (output changes every run)
_try_sibling_base() {
    local sib_dir="$1"
    [[ "${NO_CONFIG_CACHE:-0}" == "1" ]] && return 1
    [[ -f "$sib_dir/.config-base-commit" ]] || return 1
    [[ "$(cat "$sib_dir/.config-base-commit")" == "$TREE_COMMIT" ]] || return 1
    [[ -f "$sib_dir/.config-base" ]] || return 1
    cp "$sib_dir/.config-base" "$OUT_DIR/.config"
    local sib_name; sib_name=$(basename "$sib_dir" | sed 's/-[^-]*$//')
    info "Config cache hit (sibling: $sib_name): $CONFIG / $ARCH"
    return 0
}
```

The caller pattern for deterministic configs:

```bash
elif [[ $EFFECTIVE_CONFIG == kunitconfig ]]; then
    if _try_config_cache; then
        :
    elif _try_sibling_base "$BUILD_DIR/defconfig-$ARCH"; then
        _write_config_cache        # own cache written — warm runs skip sibling entirely
    elif ! kmake defconfig; then
        die ...
    else
        _write_config_cache
    fi
```

The caller pattern for random configs (unchanged logic, refactored call):

```bash
elif [[ $EFFECTIVE_CONFIG == rand500config ]]; then
    _tiny_sib="$BUILD_DIR/tinyconfig-$ARCH"
    if _try_sibling_base "$_tiny_sib"; then
        :                          # no _write_config_cache — random result each run
    elif [[ -f "$_config_base_commit" ]] && \
         [[ "$(cat "$_config_base_commit")" == "$TREE_COMMIT" ]] && \
         [[ -f "$_config_base" ]]; then
        info "Config cache hit (own base): $CONFIG / $ARCH"
        cp "$_config_base" "$OUT_DIR/.config"
    else
        kmake tinyconfig ...
        cp "$OUT_DIR/.config" "$_config_base"
        printf '%s\n' "$TREE_COMMIT" > "$_config_base_commit"
    fi
    # ... random sampling continues unchanged
```

### Correctness invariant — documented here and as a comment at the function

**Deterministic configs MUST call `_write_config_cache` after `_try_sibling_base`
returns 0.** Without this, the per-combo cache file is never written and every
subsequent run re-consults the sibling instead of the faster per-combo cache.

**Random configs MUST NOT call `_write_config_cache` after `_try_sibling_base`.**
Their final `.config` changes every run (random sampling), so a per-combo cache
would be stale immediately. They rely on the sibling every cold run.

### tinynsconfig / defnsconfig — explicit `elif` branches before the generic path

Both have `EFFECTIVE_CONFIG = tinyconfig` / `defconfig` and `NS_BASE` set.
Tinyconfig and defconfig themselves (NS_BASE="") must NOT be given a sibling
(they are the sibling source). The distinction is `[[ -n $NS_BASE ]]`:

```bash
elif [[ $EFFECTIVE_CONFIG == tinyconfig && -n $NS_BASE ]]; then
    # tinynsconfig: own cache, then tinyconfig sibling, then kmake
elif [[ $EFFECTIVE_CONFIG == defconfig && -n $NS_BASE ]]; then
    # defnsconfig: own cache, then defconfig sibling, then kmake
```

These branches must appear BEFORE the generic `elif _try_config_cache` fallthrough.

### Makefile ordering — base configs first

| Target | Old order | New order |
|---|---|---|
| `smoke` | `kunitconfig tinyconfig` | `tinyconfig kunitconfig` |
| `full` | `kunitconfig tinyconfig defconfig randdefconfig rand500config` | `defconfig tinyconfig kunitconfig randdefconfig rand500config` |
| `ns-smoke` | `kunitnsconfig tinynsconfig` | `tinynsconfig kunitnsconfig` |
| `ns-full` | `kunitnsconfig tinynsconfig defnsconfig randdefnsconfig rand500nsconfig` | `defnsconfig tinynsconfig kunitnsconfig randdefnsconfig rand500nsconfig` |

Within `make extended` (full → ns-full), all sibling bases exist by the time
ns-full starts, so ns-variants get sibling hits for the full 4-arch set.
Within a standalone `make full`, defconfig and tinyconfig run before kunitconfig,
randdefconfig, and rand500config.

---

## Testing strategy

- **`_try_sibling_base` unit tests** — missing dir, missing commit file, commit
  mismatch, commit match → copy, NO_CONFIG_CACHE=1 bypass, log message format
- **Deterministic invariant** — after sibling hit, own `.config-base` and
  `.config-cache-hash` are written; `_try_config_cache` returns 0 on the next
  call without consulting the sibling
- **Random invariant** — after sibling hit, own `.config-base` is NOT written;
  `_try_config_cache` returns 1 on the next call (correct: random output may differ)
- **Own-base fallback** — rand500config: sibling absent but own `.config-base-commit`
  present and matching → own base used, kmake skipped
- **Regression: existing three cases** — refactored rand500config, randdefconfig,
  kunitrandconfig sibling paths pass the same assertions as before refactor
- **shellcheck** — new file passes `shellcheck --severity=warning`

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, ≥70% decision paths covered

make ci-test
# Expected: all tests pass including test-sibling-reuse.sh

make all NO_FETCH=1 CONFIGS="defconfig tinyconfig kunitconfig" ARCHS=x86_64
# Expected: defconfig builds fresh, kunitconfig logs "Config cache hit (sibling: defconfig)"
# on first run; second run: kunitconfig logs "Config cache hit" (own per-combo cache)

make all NO_FETCH=1 CONFIGS="tinyconfig tinynsconfig" ARCHS=x86_64
# Expected: tinyconfig builds fresh, tinynsconfig logs "Config cache hit (sibling: tinyconfig)"
# on first run; second run: tinynsconfig logs "Config cache hit" (own per-combo cache)

make all NO_FETCH=1 CONFIGS="defconfig kunitconfig" ARCHS=riscv
# Expected: kunitconfig saves the ~5 s defconfig scan on first run
```
