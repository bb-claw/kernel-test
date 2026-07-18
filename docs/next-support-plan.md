# feat/next-support — Plan

Branch: `feat/next-support`
Start date: 2026-07-18

---

## Problem

linux-next is the integration tree where subsystem patches land before Linus pulls
them into mainline.  Testing against it exposes missing Kconfig `select` lines and
other integration issues early — before the patch even reaches an -rc tag.

Three gaps existed before this branch:

1. **No preset** — kernel-test-next had no `presets/kernel-test-next.mk`, so
   directory-based auto-dispatch did not work; `make fetch` would silently try to
   find rc tags in linux-next (and find none).

2. **No fetch-next target** — linux-next uses a daily-rebased `master` branch with
   no rc tags; neither `lib/fetch.sh` nor `lib/fetch-stable-rc.sh` handles it.

3. **Duplicated boilerplate** — `lib/fetch.sh` and `lib/fetch-stable-rc.sh` both
   set up the same `GIT=()` array and write `build/.kernel-version`.  Adding a
   third fetch script without extracting shared helpers would triple the duplication.

---

## Solution

### Shared helpers in `lib/common.sh`

Three new functions sourced by all fetch scripts:

| Function | What it does |
|---|---|
| `setup_git_array` | Sets `GIT=( git -C "$KERNEL_TREE" -c http.lowSpeedLimit=0 … )` |
| `reset_to_fetch_head` | `git reset --hard FETCH_HEAD`; dies on failure; requires `setup_git_array` first |
| `write_kernel_version` | Reads version from kernel Makefile; writes `build/.kernel-version`; sets `$KERNEL_VERSION` |

### `lib/fetch-next.sh` (new)

Mirrors `lib/fetch-stable-rc.sh` for linux-next:
- Validates origin URL contains `linux-next`
- `git fetch origin master` + `reset_to_fetch_head` + `write_kernel_version`
- Requires `LINUX_NEXT=1` (set by preset)

### `presets/kernel-test-next.mk` (new)

```makefile
KERNEL_TREE  ?= $(HOME)/git/linux-next
LABEL        ?= next
LINUX_NEXT   := 1
```

### Makefile changes

- `LINUX_NEXT ?= 0` variable + export
- `fetch` target: new `ifeq ($(LINUX_NEXT),1)` guard — prints an error directing the
  user to `make fetch-next` when accidentally run in kernel-test-next
- `fetch-next` target: runs `lib/fetch-next.sh`; errors if `LINUX_NEXT` not set
- `.PHONY` + help text updated

### `lib/fetch.sh` and `lib/fetch-stable-rc.sh`

Refactored to use the three shared helpers, removing duplicate lines.

### Documentation

- `docs/linux-next-workflow.md` — end-to-end: clone setup, patch application,
  replay verification, and full patch submission (format-patch → checkpatch →
  get_maintainer → send-email)

---

## Decisions

1. **`LINUX_NEXT := 1` in preset** — hard-assign (`:=`), not default (`?=`), so it
   cannot be accidentally overridden by a `local.mk`; the same pattern used by
   `STABLE_RC_BRANCH` in the stable-rc preset.
2. **Error on `make fetch` when `LINUX_NEXT=1`** — loud failure beats silent
   wrong behaviour (trying to find rc tags in linux-next returns nothing, leaving
   the user confused).
3. **`master` branch, not a tag** — linux-next is rebased daily; fetching
   `origin/master` is the correct strategy; `--depth=1` is NOT used here because
   linux-next needs its full `next-` tag history for `git bisect` later.
4. **Shared helpers in `common.sh`** — avoids a new `lib/fetch-common.sh` file;
   `common.sh` is already sourced by all lib scripts; three small functions fit
   cleanly under the existing helpers.
5. **`write_kernel_version` sets `$KERNEL_VERSION`** — lets callers print a final
   info line with the version without a second Makefile parse.
6. **`fetch-next` requires `LINUX_NEXT=1`** — prevents accidental use outside the
   preset-managed clone; clear error message explains the fix.

---

## Files Changed

| File | Change |
|---|---|
| `lib/common.sh` | Add `setup_git_array`, `reset_to_fetch_head`, `write_kernel_version` |
| `lib/fetch.sh` | Use `setup_git_array` |
| `lib/fetch-stable-rc.sh` | Use all three shared helpers |
| `lib/fetch-next.sh` | New: fetch linux-next master branch |
| `presets/kernel-test-next.mk` | New: KERNEL_TREE, LABEL, LINUX_NEXT |
| `Makefile` | LINUX_NEXT var/export, fetch guard, fetch-next target, help text |
| `docs/linux-next-workflow.md` | New: patch apply, replay, full submission guide |
| `CLAUDE.md` | Fetch table + key files + fetch section |
| `memory/workflows.md` | Fetch section update |
| `memory/project.md` | Current state: four clones |
| `memory/code-quality.md` | Note shared fetch helper pattern |
