# stable-rc 7.1 and 7.2 dedicated clones — Plan

Branch: `feat/stable-rc-7.1-7.2`
Start date: 2026-08-25

---

## Situation

The existing `kernel-test-stable-rc` clone tracks whichever stable-rc series is current
(`STABLE_RC_BRANCH ?= linux-7.1.y`). As the stable tree moves to 7.2, the preset must
be updated and the old series is no longer independently testable. Two new preset files
(`kernel-test-stable-rc-7.1.mk`, `kernel-test-stable-rc-7.2.mk`) were created to pin
each series permanently; this branch wires them into the harness and creates the matching
clone directories.

---

## Problems to Solve

1. **No per-series isolation** — the single stable-rc clone can only track one branch at a time; switching series requires editing a preset.
2. **No kernel-test clone for 7.1/7.2** — preset files exist but the matching harness clone directories (`kernel-test-stable-rc-7.1`, `kernel-test-stable-rc-7.2`) and kernel source trees (`linux-stable-rc-7.1`, `linux-stable-rc-7.2`) do not exist yet.

---

## Goals

1. Preset files committed: `presets/kernel-test-stable-rc-7.1.mk` + `presets/kernel-test-stable-rc-7.2.mk`
2. Harness clone `~/git/kernel-test-stable-rc-7.1` created and tracking `main`
3. Harness clone `~/git/kernel-test-stable-rc-7.2` created and tracking `main`
4. Kernel source `~/git/linux-stable-rc-7.1` created (cloned from `linux-stable-rc`), tracking `linux-7.1.y`
5. `~/git/linux-stable-rc-7.2` already exists; verified remote matches `linux-stable-rc-7.2.mk`
6. CLAUDE.md fetch-modes table updated with the two new clone dirs
7. `memory/workflows.md` updated to document the new presets

---

## Scope

Files/components changed:
- `presets/kernel-test-stable-rc-7.1.mk` — new preset; KERNEL_TREE=linux-stable-rc-7.1, GCC=gcc-15
- `presets/kernel-test-stable-rc-7.2.mk` — new preset; KERNEL_TREE=linux-stable-rc-7.2, GCC=gcc-15
- `docs/stable-rc-7.1-7.2-plan.md` — this file
- `CLAUDE.md` — fetch modes table: add rows for the two new clone dirs
- `memory/workflows.md` — document new clones under fetch mode variants

No changes to: `lib/`, `scripts/`, `tests/`, `configs/`, `Makefile` (no harness logic changes needed — preset auto-dispatch already supports the new directory names).

External directories (outside repo, created by this branch's setup):
- `~/git/kernel-test-stable-rc-7.1`
- `~/git/kernel-test-stable-rc-7.2`
- `~/git/linux-stable-rc-7.1`

---

## Non-goals

- Fetching linux-7.2.y — that branch does not yet exist on kernel.org stable-rc; `linux-stable-rc-7.2` is pre-staged infrastructure.
- Changing any harness pipeline logic — the existing `STABLE_RC_BRANCH` dispatch path handles both series unchanged.
- Moving the existing `kernel-test-stable-rc` clone — it continues tracking linux-7.1.y until retired.

---

## Design decisions

### Clone naming matches preset auto-dispatch

`$(notdir $(CURDIR))` in the Makefile loads `presets/<dir>.mk` automatically. Naming the
harness clones `kernel-test-stable-rc-7.1` and `kernel-test-stable-rc-7.2` means no
Makefile changes are needed; the right preset loads by convention.

### Kernel source clone via `git clone --local`

`linux-stable-rc-7.1` is created via `git clone --local ~/git/linux-stable-rc` to share
object store (hardlinks on same filesystem). No network fetch needed; branch `linux-7.1.y`
already present in the source clone.

### linux-stable-rc-7.2 left as-is

It already exists pointing at the stable-rc remote with `linux-7.1.y` fetched. When
`linux-7.2.y` appears on kernel.org, run `git fetch origin linux-7.2.y` inside it.
No action needed in this branch.

---

## Testing strategy

- **Preset loading** — `make info` in each new harness clone verifies the right KERNEL_TREE and STABLE_RC_BRANCH are picked up.
- **No CI test added** — preset files are static config; dispatch is tested by the existing `test-makefile-defaults.sh`. The new clone dirs are filesystem state, not harness code.

---

## Testing commands

```sh
# Always run before pushing
make dev-test

# Verify preset auto-dispatch in new harness clones
cd ~/git/kernel-test-stable-rc-7.1 && make info
# Expected: KERNEL_TREE=.../linux-stable-rc-7.1, STABLE_RC_BRANCH=linux-7.1.y

cd ~/git/kernel-test-stable-rc-7.2 && make info
# Expected: KERNEL_TREE=.../linux-stable-rc-7.2, STABLE_RC_BRANCH=linux-7.2.y

# Verify kernel source clone
git -C ~/git/linux-stable-rc-7.1 branch -a
# Expected: linux-7.1.y present
```
