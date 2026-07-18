# Stable-RC Kernel Testing Workflow

## Background

The Linux stable-rc tree (`git.kernel.org/…/stable/linux-stable-rc`) is Greg
Kroah-Hartman's testing branch for upcoming stable point releases. When Greg
announces a release candidate like `v7.1.4-rc2` on LKML, it is **not** a git
tag — it is just the current tip of the rolling `linux-7.1.y` branch.

This means:

- `make fetch` (tag-based) and `make checkout TAG=v7.1.4-rc2` will both fail
  with "couldn't find remote ref v7.1.4-rc2"
- The branch must be fetched by name and HEAD reset to its tip
- `make fetch-stable-rc` handles this correctly

## Workflow

### One-time setup

Clone the test harness into a directory named `kernel-test-stable-rc`:

```sh
git clone https://github.com/bb-claw/kernel-test.git kernel-test-stable-rc
cd kernel-test-stable-rc
make bootstrap
```

The preset `presets/kernel-test-stable-rc.mk` is auto-loaded by the Makefile
(directory-name detection). It sets `KERNEL_TREE`, `LABEL`, `GCC`,
`BUILD_TIMEOUT`, and `STABLE_RC_BRANCH` — no manual configuration needed.

### When a new stable-rc is announced

```sh
# In kernel-test-stable-rc/
make fetch-stable-rc          # fetches linux-7.1.y, resets HEAD, writes .kernel-version
make smoke                    # kunitconfig + tinyconfig (quick sanity)
make all NO_FETCH=1           # full pipeline
```

`make fetch-stable-rc`:
1. Runs `git fetch origin linux-7.1.y` in `KERNEL_TREE`
2. Resets HEAD to the fetched tip
3. Reads the version from the kernel Makefile fields (VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION)
4. Writes the result (e.g. `v7.1.4-rc2`) to `build/.kernel-version`
5. Prints the fetched version

After the fetch, `build/.kernel-version` is up to date. All subsequent
`make all NO_FETCH=1` invocations show the correct version in the `[build]`
header and use it for the report directory name.

### Check what is currently checked out

```sh
make info    # shows HEAD commit, nearest git tag, kernel Makefile version, .kernel-version
```

### Update the branch name when the stable series bumps

When the 7.1.y series reaches end-of-life and 7.2.y starts, update the preset:

```sh
# In presets/kernel-test-stable-rc.mk
STABLE_RC_BRANCH ?= linux-7.2.y
```

Commit and push. All three repos pull from the same `main` branch, so the
update propagates automatically on the next `git pull`.

## Why not make fetch?

`make fetch` uses `git ls-remote` to discover tags matching `v*-rc*` or
`vX.Y.*`. The stable-rc remote has no such tags for point-release candidates.
Attempting `git fetch --depth=1 origin v7.1.4-rc2` fails because that ref
simply does not exist on the remote.

The stable-rc workflow is fundamentally branch-based, not tag-based.

## Contrast with stable releases

For final stable releases (e.g. `v7.1.3`), Greg *does* create real git tags.
Use `make fetch-stable` for those:

```sh
# In kernel-test-stable/
make fetch-stable           # fetches latest v7.1.x tag (STABLE_RELEASE=7.1 from preset)
make all NO_FETCH=1
```

## KERNEL_VERSION display

The Makefile shows `[build] Kernel: <version>` at the start of each build.
This reads `build/.kernel-version` first. If the file is stale (e.g. the
kernel was updated by a direct `git fetch` bypass), the Makefile falls back to:

1. `git describe --exact-match HEAD` — exact tag match (fails for untagged)
2. `make kernelversion` in the kernel tree — reads Makefile fields directly
3. `git rev-parse --short HEAD` — short SHA (honest but opaque)

`make fetch-stable-rc` always writes a fresh `.kernel-version`, so the display
is correct when the harness fetch targets are used.
