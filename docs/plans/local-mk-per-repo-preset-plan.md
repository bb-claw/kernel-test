# fix/local-mk-per-repo-preset — Plan

Branch: `fix/local-mk-per-repo-preset`
Start date: 2026-07-17

---

## Problem

All three repos (`kernel-test`, `kernel-test-stable`, `kernel-test-stable-rc`) are
local clones of the same GitHub repository (`bb-claw/kernel-test`). They share one
`main` branch and one git history.

`local.mk` was committed in both `kernel-test-stable` and `kernel-test-stable-rc` with
**different contents**. When both push to `main`, they conflict — the second push
requires a rebase, which produces a merge conflict on `local.mk`. The committed
`local.mk` on `main` can only hold one content at a time; every pull clobbers the
other clone's settings.

Root cause: a file with clone-specific content must not be committed to the shared
history. The current `-include local.mk` mechanism is correct as a concept, but the
file needs to be either:

1. **Never committed** (gitignored, created locally by the user), or
2. **Auto-selected from committed named files** based on something that differs per
   clone (directory name, git remote branch, etc.)

---

## Proposed Fix: Directory-Name Auto-Detection

The Makefile detects the basename of `$PWD` at parse time and includes the matching
preset file from a `presets/` directory. Each preset file is committed to the repo
under a unique name — no conflicts.

```makefile
# Auto-include preset based on directory name, then local.mk override on top.
REPO_DIR := $(notdir $(CURDIR))
-include presets/$(REPO_DIR).mk
-include local.mk
```

Committed preset files:

| File | Content |
|---|---|
| `presets/kernel-test-stable.mk` | `STABLE_RELEASE ?= 7.1` |
| `presets/kernel-test-stable-rc.mk` | `KERNEL_TREE ?= ~/git/linux-stable-rc` + `LABEL`, `GCC`, `BUILD_TIMEOUT` |

`kernel-test` (mainline) has no preset — the default `?=` values apply.

`local.mk` remains as a user-level override included *after* the preset, so any
variable can still be overridden machine-locally without touching git.

---

## Alternatives Considered

### A: Gitignore `local.mk` + ship example files

Add `local.mk` to `.gitignore`. Commit `local.mk.example-stable` and
`local.mk.example-stable-rc` as documentation. User copies the right example on
first clone.

- Pro: zero Makefile complexity
- Con: manual setup step per clone; easy to forget; no automation

### B: Single `PROFILE=` variable in `local.mk`

Commit one thin `local.mk` per clone that sets `PROFILE=stable-rc`. Makefile
then includes `presets/$(PROFILE).mk`. User names the profile, not the directory.

- Pro: decouples preset from directory name (works if dirs are renamed)
- Con: still requires a committed per-clone file → same conflict problem

### C: Git remote URL detection

`$(shell git remote get-url origin)` → parse to derive the profile. Fragile if
remotes change; adds a shell invocation to every Makefile parse; hard to test.

---

## Files Changed

| File | Change |
|---|---|
| `Makefile` | Replace `-include local.mk` with two-line auto-detect + override |
| `presets/kernel-test-stable.mk` | New: stable preset |
| `presets/kernel-test-stable-rc.mk` | New: stable-rc preset |
| `local.mk` (root) | Remove from git history (was wrongly committed); add to `.gitignore` |
| `.gitignore` | Add `local.mk` |
| `CLAUDE.md` | Update `local.mk` convention; document `presets/` |
| `memory/workflows.md` | Update Variables table |

---

## Decisions

1. **Detection**: directory name (`$(notdir $(CURDIR))`) — zero setup after clone
2. **Location**: `presets/` directory — clean separation from kernel config fragments
3. **Override**: `local.mk` kept as gitignored user override, included after the preset
4. **Scope**: stable + stable-rc only — mainline uses Makefile defaults as-is
