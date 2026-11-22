# feat/stable-rc-fetch-tooling — Plan

Branch: `feat/stable-rc-fetch-tooling`
Start date: 2026-07-18

---

## Problem

The harness has one fetch path: `make fetch` discovers and fetches the latest `v*-rc*`
or `vX.Y.*` git tag from `KERNEL_TREE`. This works for:

- **Mainline** — tags like `v7.2-rc3` always exist
- **Stable release** — tags like `v7.1.3` always exist

It does **not** work for **stable-rc** (Greg KH's `linux-stable-rc` testing branch):

- `v7.1.4-rc2` is never a real git tag — it is announced on LKML but lives only as
  the tip of the `linux-7.1.y` branch in the `linux-stable-rc` remote
- `make fetch` (tag-based) fails with "couldn't find remote ref v7.1.4-rc2"
- After a manual `git fetch origin linux-7.1.y && git reset --hard FETCH_HEAD`,
  `build/.kernel-version` is stale (still holds the previous run's version)
- The Makefile displays the wrong version in `[build] Kernel: <version>` because
  `cat build/.kernel-version` is the first fallback and returns stale data

Secondary problem: `make fetch` is the only named fetch target. `make fetch-stable`
does not exist — users must remember to pass `STABLE_RELEASE=X.Y` manually even though
the preset already sets it.

---

## Proposed Fix

### Auto-dispatching `make fetch`

`make fetch` auto-dispatches based on the preset loaded for the current clone:

| Clone directory | Preset sets | `make fetch` does |
|---|---|---|
| `kernel-test` | _(nothing)_ | `git ls-remote` → `fetch --depth=1 v*-rc*` tag |
| `kernel-test-stable` | `STABLE_RELEASE=7.1` | `git ls-remote` → `fetch --depth=1 vX.Y.*` tag |
| `kernel-test-stable-rc` | `STABLE_RC_BRANCH=linux-7.1.y` | `git fetch origin linux-7.1.y` + `git reset --hard FETCH_HEAD` |

`make fetch-stable` and `make fetch-stable-rc` are kept as explicit override targets
for use outside the preset-managed clones.

### KERNEL_VERSION fallback fix

Add `make -s -C kernelversion` between the `git describe --exact-match` and SHA
fallbacks so untagged branch tips display the correct version from the kernel's own
Makefile fields:

```makefile
KERNEL_VERSION := $(shell cat $(BUILD_DIR)/.kernel-version 2>/dev/null \
    || git -C "$(KERNEL_TREE)" describe --exact-match HEAD 2>/dev/null \
    || make -s -C "$(KERNEL_TREE)" kernelversion 2>/dev/null \
    || git -C "$(KERNEL_TREE)" rev-parse --short HEAD 2>/dev/null \
    || echo unknown)
```

`rev-parse --short HEAD` is a last resort (opaque SHA); `make kernelversion` returns a
semantic version (e.g. `7.1.4-rc2`) and is always preferred over the SHA fallback.

### Stable-rc fetch script: `lib/fetch-stable-rc.sh`

```
git -C $KERNEL_TREE fetch origin $STABLE_RC_BRANCH
git -C $KERNEL_TREE reset --hard FETCH_HEAD
version=$(make -s -C $KERNEL_TREE kernelversion)
echo "$version" > $BUILD_DIR/.kernel-version
log INFO "Fetched $STABLE_RC_BRANCH → $version"
```

### Preset update: `presets/kernel-test-stable-rc.mk`

```makefile
STABLE_RC_BRANCH ?= linux-7.1.y
```

---

## Alternatives Considered

### A: Extend make fetch with STABLE_RC_BRANCH detection

If `STABLE_RC_BRANCH` is set, `lib/fetch.sh` could switch to branch-fetch mode.
- Pro: single script, fewer targets
- Con: one script doing two very different things (tag fetch vs branch fetch);
  harder to read, harder to test; target names still ambiguous

### B: Auto-derive branch from kernel Makefile PATCHLEVEL

Read `PATCHLEVEL` from `KERNEL_TREE/Makefile`, build `linux-X.Y.y` automatically.
- Pro: zero setup after clone
- Con: spawns a shell at Makefile parse time for every `make` invocation;
  if the tree is missing or dirty, the result is silently wrong

### C: Require BRANCH= on command line every time

No default; user passes `BRANCH=linux-7.1.y` explicitly.
- Pro: transparent
- Con: defeats the purpose of tooling; easy to forget or mistype

---

## Files Changed

| File | Change |
|---|---|
| `Makefile` | Auto-dispatch `make fetch` by preset; `make kernelversion` fallback in `KERNEL_VERSION` chain; add `fetch-stable` and `fetch-stable-rc` override targets; export `STABLE_RC_BRANCH`; update `make help` |
| `lib/fetch-stable-rc.sh` | New: branch fetch + reset + `.kernel-version` write + version display |
| `presets/kernel-test-stable-rc.mk` | Add `STABLE_RC_BRANCH ?= linux-7.1.y` |
| `CLAUDE.md` | Document three-clone setup and `make fetch` auto-dispatch; add stable-rc workflow; link to design doc |
| `memory/workflows.md` | Add `STABLE_RC_BRANCH` to variables table; update fetch dispatch explanation |
| `memory/project.md` | Add `lib/fetch-stable-rc.sh` to architecture diagram + lib listing; preset auto-dispatch in Key Decisions |
| `docs/stable-rc-workflow.md` | New: user-facing guide for stable-rc testing workflow |

---

## Decisions

1. **Auto-dispatching `make fetch`** — same command in all three clones; `ifeq`/`else ifneq` on `STABLE_RC_BRANCH`/`STABLE_RELEASE` selects the right implementation; named override targets kept for explicit use
2. **Branch name from preset** — `STABLE_RC_BRANCH ?= linux-7.1.y` in `presets/kernel-test-stable-rc.mk`; version bump is a one-line change in one committed file
3. **Post-fetch**: fetch + reset + `.kernel-version` write + version display
4. **Docs**: `CLAUDE.md` + `memory/workflows.md` + `make help` + `docs/stable-rc-workflow.md`
5. **Separate script** — `lib/fetch-stable-rc.sh` rather than extending `lib/fetch.sh`; keeps each script single-purpose
6. **KERNEL_VERSION order** — `make kernelversion` before `rev-parse --short HEAD`; semantic version beats opaque SHA for stable-rc untagged commits
