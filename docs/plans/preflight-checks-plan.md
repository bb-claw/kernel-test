# Preflight Checks — Plan

Branch: `feat/preflight-checks`
Start date: 2026-09-26

---

## Situation

`lib/build.sh` and other pipeline scripts discover missing tools late — deep inside a build
loop, buried in a log, often hours into a run. The immediate trigger was Hetzner staging
silently building with stale `fixdep` for months after `GCC=gcc-15` was added to the stable
preset, then failing with a cryptic ccache error the first time a fresh build dir was needed.
A centralized preflight layer catches these problems at `make all` entry, before any work starts.

---

## Problems to Solve

1. **Silent late failure** — Missing compiler/QEMU discovered inside a per-(config,arch) log,
   not at pipeline start; user sees confusing ccache or cross-compiler errors.
2. **No cross-compiler validation** — `arm64`/`riscv` builds silently fail if
   `aarch64-linux-gnu-gcc` / `riscv64-linux-gnu-gcc` are absent; no early signal.
3. **No disk-space gate** — BUILD_DIR or CACHE_DIR can fill mid-run, producing partial
   results and corrupted ccache state.
4. **scripts/ tools unchecked** — `verify-patch.sh`, `bisect`, `kconfig-build`, and
   `perf-build` start long runs before discovering missing required arguments or library deps.

---

## Goals

1. `make preflight` runs standalone and exits non-zero with a clear, actionable message for
   each missing tool or condition.
2. `make all` and `make build` automatically run preflight first; failures abort before any
   build loop starts.
3. `verify-patch.sh`, `scripts/config-bisect.sh`, `scripts/kconfig-build.sh`, and
   `lib/build.sh` (perf-build deps) each run their own targeted preflight before starting.
4. `tests/ci/test-preflight.sh` covers ≥ 8 distinct failure paths via PATH manipulation;
   passes on every supported CI host.

---

## Scope

Files/components changed:
- `lib/preflight.sh` *(new)* — centralized checks: host compiler, cross-compilers per ARCH,
  QEMU binaries per ARCH, disk space for BUILD_DIR and CACHE_DIR
- `Makefile` — add `preflight` target; call it from `build` and `all`
- `lib/build.sh` — remove ad-hoc GCC check (superseded by preflight); add perf-build dep
  checks (`libelf`, `libdw`, `pkg-config`, `python3-dev`, `libtraceevent`) inside the
  `perf-build` path
- `scripts/verify-patch.sh` — check FILES= provided; BASE= is a valid git ref if set;
  clang+lld present when COMPILER=clang|both
- `scripts/config-bisect.sh` — check CONFIG_FILE= provided and file readable
- `scripts/kconfig-build.sh` / `scripts/kconfig-check.sh` — check SUBSYSTEM= provided
- `tests/ci/test-preflight.sh` *(new)* — CI tests via PATH stub manipulation

No changes to: `vm.sh`, `initramfs.sh`, `report.sh`, fetch scripts — their prerequisites
(kernel image, initramfs) are already validated by Makefile file prerequisites.

---

## Non-goals

- Hardware board checks (`make hw*`) — board TTY / relay presence is runtime-only.
- Network connectivity checks — `make fetch` already handles TLS errors with a fallback.
- Compiler version checks beyond existence — out of scope; kernel Makefile's `ld-version.sh`
  already enforces minimums.

---

## Design decisions

### Centralized lib/preflight.sh, not per-script inline

Each lib script could check its own deps, but that produces duplicate code and means the
*second* build failing tells you about the *first* build's missing tool. A single
`lib/preflight.sh` sourced (or called) once at pipeline entry surfaces all issues together.
scripts/ tools keep their own checks because they run independently, not via the pipeline.

### Hard-fail on every missing tool

Warn-and-skip was considered for QEMU TCG arches (arm64/riscv), but a missing QEMU means
the run silently produces incomplete results. Explicit `ARCHS=x86_64` is the right way to
skip an arch; an absent binary should never silently drop results.

### Disk space thresholds: 5 GB BUILD_DIR, 5 GB CACHE_DIR

Conservative thresholds that catch nearly-full disks without false positives on small
single-config runs (`CONFIGS=tinyconfig` needs <1 GB). Overridable via
`MIN_BUILD_SPACE_GB` and `MIN_CACHE_SPACE_GB` in `local.mk`.

### perf-build deps in lib/build.sh, not lib/preflight.sh

`perf-build` is an opt-in target (`NO_PERF_BUILD=1` skips it). Putting its library checks
in `lib/preflight.sh` would make the global preflight fail on hosts that intentionally skip
perf. Instead, `lib/build.sh` checks deps inline, immediately before the perf build step,
only when `NO_PERF_BUILD != 1`.

### scripts/ preflight is inline, not via lib/preflight.sh

`scripts/` tools are invoked directly (`make verify-patch`, `make bisect`) — they don't go
through the pipeline entry point. Each script validates its own required args/tools at
startup with the same die-early pattern.

---

## Testing strategy

- **Happy path** — run `make preflight` on the real host; assert exit 0 and "all checks
  passed" message.
- **Missing compiler** — PATH stub without `gcc`; assert exit 1, message mentions `GCC`.
- **Missing cross-compiler** — PATH stub without `aarch64-linux-gnu-gcc` but ARCHS includes
  arm64; assert exit 1, message mentions arch and compiler name.
- **Missing QEMU** — PATH stub without `qemu-system-riscv64` but ARCHS includes riscv;
  assert exit 1, message mentions QEMU binary name.
- **Low disk space** — not mockable without root; tested via a stub `df` that emits a
  low-space value.
- **Multiple failures** — omit two stubs; assert exit 1 and both errors appear in output
  (preflight collects all errors, not fail-fast on first).
- **scripts/ arg checks** — run each script without required var; assert exit 1 and message
  names the missing variable.
- **No tests for perf-build deps** — `pkg-config` output mocking is fragile; covered by
  `make bootstrap` docs instead.

---

## Testing commands

```sh
# Always run before pushing any branch
make dev-test
# Expected: exit 0, ≥50% decision paths covered within time budget

# 1. Standalone preflight passes on this host
make preflight
# Expected: exit 0, "Preflight: all checks passed"

# 2. Full CI suite including new test
make ci-test
# Expected: exit 0, test-preflight.sh shows all cases pass

# 3. Preflight fires at make build entry
make build NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64
# Expected: preflight output before any [build] lines

# 4. Missing tool caught before any build starts (simulate by unsetting PATH entry)
PATH=/usr/bin:/bin make preflight GCC=gcc-99
# Expected: exit 1, "Host compiler 'gcc-99' not found in PATH"

# 5. verify-patch.sh arg check
make verify-patch
# Expected: exit 1, "FILES= required"

# 6. bisect arg check
make bisect
# Expected: exit 1, "CONFIG_FILE= required"
```
