# GitHub Actions CI — Plan

Branch: `feat/github-actions-ci`
Start date: 2026-08-20

---

## Situation

The harness has two solid CI tiers (`make lint`, `make ci-test`) and a programs build
(`make programs`) that covers 4 arches. These run locally and via `make dev-test` but
are not enforced on PRs — a contributor can merge broken shellcheck or a missing
test-inventory entry without any automated gate. GitHub Actions closes this gap with
zero infrastructure cost using ubuntu-latest runners.

---

## Problems to Solve

1. **No automated PR gate** — lint and ci-test are only run if the author remembers;
   nothing blocks a merge on failure.
2. **Cross-arch compile not verified in CI** — snapshot/syscall-tests/perf-event could
   silently break for arm64 or riscv without a programs build in the pipeline.

---

## Goals

1. `.github/workflows/ci.yml` runs on every PR to `main`.
2. Three sequential steps: `make lint` → `make ci-test` → `make programs`; fail fast on
   first failure.
3. Toybox binaries cached by `TOYBOX_VERSION` so repeated runs don't re-download.
4. Workflow registered as a required status check on `main`; PRs cannot merge until green.

---

## Scope

Files/components changed:
- `.github/workflows/ci.yml` — new workflow file
- `tests/ci/test-arena-test.sh` — main build x86_64-only; graceful i386 skip test added
- `tests/ci/test-perf-event.sh` — same
- `tests/ci/test-snapshot.sh` — same
- `tests/ci/test-syscall-tests.sh` — same (pre-existing `st-i386-build` test fixed to trigger its own build)
- `Makefile` — `make ci` target added (mirrors GitHub Actions pipeline locally)
- `memory/workflows.md`, `docs/github-actions-ci-plan.md`, `CLAUDE.md` — documentation updated

---

## Non-goals

- Running VM boots in CI — requires KVM; ubuntu-latest has no `/dev/kvm`; `make dev-test`
  covers this locally and on hetzner.
- Self-hosted runner setup — GitHub-hosted ubuntu-latest is sufficient for the three
  targets chosen; avoids runner maintenance burden.
- `push` to all branches trigger — PR-only keeps noise low; authors run `make lint`
  locally via the pre-push hook before opening a PR.
- `workflow_dispatch` — not needed; manual re-runs work via GitHub UI on any run.

---

## Design decisions

### Sequential steps, fail fast

`make lint` → `make ci-test` → `make programs` run as sequential `run:` steps in one
job. A lint failure aborts before the longer ci-test; a ci-test failure aborts before
the compile. This matches the pre-push hook ordering and gives the fastest signal for
the most common failure (shellcheck).

Alternative considered: parallel jobs per target — rejected because the 3 steps
together take ~90s total; parallelism adds workflow complexity for negligible wall-clock
savings, and lint failures make ci-test results meaningless anyway.

### ubuntu-22.04 runner

`make lint` needs only bash + shellcheck. `make ci-test` runs tests/ci/test-*.sh (no QEMU).
`make programs` needs cross-compilers + musl. ubuntu-22.04 is used instead of ubuntu-latest
because `gcc-multilib` (needed for i386 `-m32`) conflicts with `gcc-aarch64-linux-gnu` and
`gcc-riscv64-linux-gnu` at the package level on Ubuntu — both cannot be installed simultaneously.
i386 is excluded from the CI programs build (`ARCHES="x86_64 arm64 riscv"`); the per-test-file
i386 build tests in tests/ci/test-*.sh skip gracefully when `gcc -m32` is unavailable.
musl-clang wrapper must be created manually (same as `make bootstrap` does on Debian — a thin
shell wrapper pointing clang at musl headers). `socat` is also required by tests/ci/test-*.sh.

### Toybox cache

`actions/cache` keyed on `TOYBOX_VERSION` (read from Makefile via `grep`). Cache miss
on first run or version bump; hit on subsequent runs. Saves ~2s and avoids hitting the
toybox.net download server on every push. Cache path: `cache/` (gitignored, same as
local).

### Required status check

After the first successful CI run, add the workflow as a required status check on `main`
via GitHub branch protection settings (Settings → Branches → main → Require status
checks). The check name will be the job name defined in the workflow.

### `make programs` without QEMU packages

`make programs` builds C binaries only — it does not invoke QEMU or build the kernel.
The Makefile programs target calls `make -C tests/programs` and `make -C tests/ns`.
No QEMU or kernel build tools (flex, bison, bc, libelf) needed. `make programs` is
safe to run on ubuntu-latest without kernel build deps.

---

## Package install list (ubuntu-22.04)

```
# Lint
shellcheck

# C programs build — x86_64 (no gcc-multilib: conflicts with aarch64/riscv cross-compilers)
gcc musl-tools

# C programs build — arm64
gcc-aarch64-linux-gnu libc6-dev-arm64-cross

# C programs build — riscv
gcc-riscv64-linux-gnu libc6-dev-riscv64-cross

# clang quality gate (musl-clang wrapper)
clang lld llvm

# ci-test (serial-capture test fixture)
socat
```

i386 excluded: `gcc-multilib` conflicts with `gcc-aarch64-linux-gnu` / `gcc-riscv64-linux-gnu`
on Ubuntu at the package level. programs build uses `ARCHES="x86_64 arm64 riscv"`.
tests/ci/test-*.sh skip i386 build tests gracefully when `gcc -m32` is unavailable.

musl-clang: `musl-tools` provides `musl-gcc` but not `musl-clang`. Wrapper script
created at `/usr/local/bin/musl-clang` (same approach as `make bootstrap` on Debian)
pointing clang at `/usr/lib/x86_64-linux-musl/`.

---

## Testing strategy

- **Workflow syntax** — `act` (local GitHub Actions runner) or push to a draft PR and
  observe the Actions tab.
- **Cache hit** — verify on second run that "Cache hit" appears in the actions/cache step.
- **Failure path** — temporarily break a test script (bad shellcheck), confirm CI fails
  at lint and does not proceed to ci-test.
- **Green path** — full PR run completes all three steps in ≤2 min.

---

## Testing commands

```sh
# Verify the workflow YAML is valid locally
python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo OK

# Simulate the apt install + programs build locally (Debian/Ubuntu only)
sudo apt-get install -y gcc gcc-multilib musl-tools \
    gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
    gcc-riscv64-linux-gnu libc6-dev-riscv64-cross \
    clang llvm lld shellcheck
make programs
# Expected: all 4 arches compile clean

# Open a draft PR and watch Actions tab
gh pr create --draft --title "feat(ci): add GitHub Actions workflow" --body "CI verification"
# Expected: workflow triggers, all steps green within ~2 min
```
