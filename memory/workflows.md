# Workflows & Make Commands

## Variables

| Variable | Default | Override example |
|---|---|---|
| `KERNEL_TREE` | `../linux` | `KERNEL_TREE=~/git/linux-stable` |
| `STABLE_KERNEL_TREE` | `~/git/linux-stable` | — |
| `STABLE_RELEASE` | _(none)_ | `STABLE_RELEASE=7.1` |
| `TAG` | _(none)_ | `TAG=v7.2-rc2` (used by `make checkout` only) |
| `ARCHS` | `x86_64 i386` | `ARCHS=x86_64` |
| `CONFIGS` | all 7 profiles | `CONFIGS=defconfig` |
| `TIMEOUT` | `60` | `TIMEOUT=120` |
| `BUILD_TIMEOUT` | `600` | `BUILD_TIMEOUT=900` |
| `NO_FETCH` | `0` | `NO_FETCH=1` |
| `V` | `0` | `V=1` |

`KERNEL_TREE` is tilde-expanded and absolutified at Makefile parse time.
When `STABLE_RELEASE` is set, `KERNEL_TREE` is automatically overridden to `STABLE_KERNEL_TREE`.

---

## Common Workflows

### Full pipeline — latest mainline rc

```sh
make KERNEL_TREE=~/git/linux-stable
```

### Full pipeline — specific rc version

```sh
make checkout TAG=v7.2-rc2 KERNEL_TREE=~/git/linux-stable
make all NO_FETCH=1 KERNEL_TREE=~/git/linux-stable
```

### Full pipeline — latest stable release

```sh
make STABLE_RELEASE=7.1
```

### Full pipeline — specific stable version

```sh
make checkout TAG=v7.1.3 STABLE_RELEASE=7.1
make all NO_FETCH=1 STABLE_RELEASE=7.1
```

### Quick re-run (skip fetch + build, just initramfs + test + report)

```sh
make CONFIGS=defconfig initramfs test report
```

### Single config, single arch

```sh
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64
```

### Re-run tests only (build already done)

```sh
make CONFIGS=rand500config initramfs test report
```

### Verbose build output

```sh
make all NO_FETCH=1 V=1 KERNEL_TREE=~/git/linux-stable
```

### Check what is currently checked out

```sh
make info KERNEL_TREE=~/git/linux-stable
```

---

## Rule: Always Use `make all`, Not Chained Targets

**Wrong:** `make build initramfs test report` — stops at first failure, report never written.

**Correct:** `make all NO_FETCH=1 ...` — always writes report even when build or test fails.

The `all` target uses:
```makefile
rc=0; \
$(MAKE) build    || rc=1; \
$(MAKE) initramfs || true; \
$(MAKE) test     || rc=1; \
$(MAKE) report; \
exit $rc
```

---

## Fetch Strategy

Both modes: `git ls-remote` to discover tag (no objects), then `git fetch --depth=1 <tag>`.
If tag already local, fetch is skipped entirely.

- **Mainline rc:** latest `v*-rc*` tag from `KERNEL_TREE`
- **Stable:** latest `vX.Y.*` (non-rc) from `STABLE_KERNEL_TREE`; remote URL verified to contain `/stable/` or `linux-stable`

---

## Build Timeout

`BUILD_TIMEOUT` (default 600 s) wraps only the `bzImage` build step via `timeout(1)`.
Exit 124 → `STATUS=TIMEOUT` in `build.status` (distinct from `STATUS=FAIL`).
Config step and fragment step are NOT wrapped — they are fast.

---

## i386 Limitation

Host BusyBox is 64-bit. i386 initramfs falls back to a minimal C init (`gcc -m32 -static`).
Result: i386 always shows `0/0` tests (boot-only verification, no test scripts).
This is expected; x86_64 provides full test coverage.
