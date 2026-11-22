# build: fix kernel version display on stable-rc clones — Plan

Branch: `fix/build-version-stable-rc`
Start date: 2026-09-13

---

## Situation

`lib/build.sh` displays the kernel version at the start of every build step
(e.g. `Kernel: v7.2.6-rc1 (048ea6124e84) — …`). It attempts an exact tag
match first; if that fails it falls back to `git describe --tags --abbrev=0`.
On stable-rc clones the branch tip (e.g. `linux-7.2.y` HEAD) is never tagged
exactly — tags like `v7.2.6-rc1` live in the stable release repo, not in the
`linux-stable-rc` remote. The `--abbrev=0` fallback walks back to the nearest
ancestor tag, which belongs to a different series (e.g. `v7.1-rc7`), so every
build log line misreports the kernel version.

---

## Problems to Solve

1. **Wrong version in build log** — `Kernel: v7.1-rc7 (048ea6124e84)` is shown
   when the tree is actually `7.2.6-rc1`. The SHA is correct but the tag label
   is misleading; operators and CI tooling that grep build logs for version
   strings get incorrect data.

2. **No CI coverage** — the `git describe` fallback path in `build.sh` is
   untested; any future regression would be silent.

---

## Goals

1. `build.sh` displays the correct kernel version on stable-rc clones by
   reading from the kernel Makefile when no exact tag exists at HEAD.
2. A CI test (`tests/ci/test-build-version.sh`) covers both the stable-rc
   scenario (no tag at HEAD, ancestor has old tag) and the mainline scenario
   (exact tag at HEAD).

---

## Scope

Files changed:
- `lib/build.sh` — replace `git describe --tags --abbrev=0` fallback with
  `read_kernel_makefile_version` (already defined in `lib/common.sh`, already
  sourced at the top of `build.sh`)
- `tests/ci/test-build-version.sh` — new CI test (6 assertions)

No changes to: `lib/common.sh` (function already correct),
`lib/checkout.sh` (uses `rev-parse --short` as fallback — safe; it labels
by commit hash, not a version claim), `lib/report.sh` (already uses
`read_kernel_makefile_version`), any VM test scripts.

---

## Non-goals

- Pulling stable release tags into the `linux-stable-rc` remote — unnecessary
  overhead; reading the Makefile is authoritative and cheaper.
- Changing the fetch workflow or version file written by `write_kernel_version`
  — those already use the Makefile path.

---

## Root cause analysis

`git describe --tags --abbrev=0 HEAD`:
- `--abbrev=0` suppresses the commit-count suffix (e.g. `-14-gabcdef`), making
  the output look like a clean tag name.
- It still resolves to the *nearest ancestor tag*, not the tag *at* HEAD.
- On `linux-7.2.y` with no `v7.2.6-rc1` tag in the repo, the nearest tag is
  from the previous series (`v7.1-rc7`).

`read_kernel_makefile_version`:
- Reads VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION directly from
  `$KERNEL_TREE/Makefile`.
- Returns `v7.2.6-rc1` for a stable point-release RC, `v7.2-rc5` for a
  mainline RC.
- `report.sh` already uses this for the same reason (noted in project memory).

### Why `checkout.sh` is unaffected

`checkout.sh`'s fallback is `git rev-parse --short HEAD` (a commit hash, not a
version claim). It is only used when the user explicitly passes a non-tag REF.
The Makefile cross-check at line 63 would catch divergence.

---

## Design decisions

### Use `read_kernel_makefile_version` as the fallback

**Chosen.** Consistent with `report.sh`. The Makefile is the authoritative
source of the kernel version; `git describe` is a convenience that only works
reliably when the repo contains the release tags.

**Alternative: fetch the stable-rc tags into the repo** — rejected; requires
network access during builds and adds an unpredictable tag set from the remote.

**Alternative: parse the commit message** — rejected; commit message format is
not guaranteed by Kbuild; Makefile format is.

---

## Testing strategy

- **CI test** — `tests/ci/test-build-version.sh`: creates isolated fake kernel
  trees (no kernel build required), tests the `git describe` + Makefile
  fallback logic directly. Six assertions cover mainline (tag at HEAD) and
  stable-rc (no tag, ancestor has old tag from a different series).
- **No VM test** — version display is a logging-only concern; no runtime
  behaviour changes.
- **Manual verification** — `make all CONFIGS=rand500nsconfig` on a
  `kernel-test-stable-rc` clone now shows the correct version.

---

## Testing commands

```sh
# Always run before pushing
make dev-test

# Run the new CI test in isolation
bash tests/ci/test-build-version.sh
# Expected: 6/6 pass, exit 0

# Full Tier 2 CI
make ci-test
# Expected: all test-*.sh pass, exit 0

# Verify fix on a stable-rc clone (requires linux-stable-rc checkout):
#   make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64
# Build log should show: Kernel: v7.2.6-rc1 (048ea6...) — …
# NOT:                   Kernel: v7.1-rc7 (048ea6...) — …
```
