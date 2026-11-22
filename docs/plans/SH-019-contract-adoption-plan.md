# SH-019 — contract-adoption: plan

**Story**: Tracked in shepherd ([SH-019](https://github.com/bboortz/shepherd/blob/main/docs/stories/SH-019-fleet-contract-rollout.md) under the [SH-014 umbrella](https://github.com/bboortz/shepherd/pull/23))
**Branch**: `feat/SH-019-contract-adoption`
**Status**: in-progress

---

## Situation

Shepherd's SH-014 umbrella defines an eight-target `make` contract (`build`, `test`, `test-affected`, `smoke`, `release-artifacts`, `ci-branch`, `ci-patch`, `ci-release`, `ci-nightly`) that every managed repo exposes. Kernel-test is one of six managed repos. The dev-cycle research brief (2026-11-22) flagged kernel-test's specific gap: "`.shepherd.yml` tells Shepherd to run `make build` and `make test`. `make -n` shows … Kernel-Test's `make test` needs a kernel tree that a clean runner does not have." The prescription: "set `build: make programs` and `test: make ci-test`."

---

## Problems to solve

1. **Clean-runner failure** — shepherd's reusable workflow runs `make build` + `make test` on a fresh runner; native `build` fetches and compiles kernels, native `test` depends on `BOOT_CONFIGS × ARCHS` kernel builds. Both need a kernel tree.
2. **No contract shape today** — kernel-test has `lint`, `programs`, `smoke`, `ci-test`, `build`, `test`, but none of the four tiered `ci-*` targets or the three agent entry points (`test-affected`, `smoke`-contract-shape, `release-artifacts`).

---

## Goals

1. `shepherd-bump --verify-contract` (SH-017, pending) will pass on kernel-test.
2. Shepherd's reusable workflow runs `make build` (→ `programs`) and `make test` (→ `ci-test`) successfully on a clean runner.
3. All eight contract targets resolve (`make -n`) to real, bounded work.
4. No behaviour change for interactive use: native `build` / `test` / `programs` / `smoke` / `ci-test` keep their existing semantics.

---

## Scope

Files changed:

- `Makefile` — 30 new lines appended under a new `##@ Shepherd dev-cycle contract (SH-014 / SH-019)` section. New targets: `test-affected`, `release-artifacts`, `ci-branch`, `ci-patch`, `ci-release`, `ci-nightly`, `ci-nightly-body`. Zero edits to existing targets.
- `.shepherd.yml` — two-line change: `build: make` → `build: make programs`; `test: make test` → `test: make ci-test`. This is the exact dev-cycle-doc prescription.

No changes to: existing `build` / `test` / `programs` / `smoke` / `ci-test` recipes; existing workflow YAML; test scripts; CI configuration.

---

## Design delta

Contract tier bodies bypass the heavy native `build` + `test` (which need a kernel tree) and invoke `programs` + `ci-test` directly:

- `test-affected: ci-test` — framework tests only; fast; clean-runnable. No affected-only mechanism exists in kernel-test today; SH-024 will add artifact-cache-keyed `(ref, config, toolchain)` nightly builds.
- `release-artifacts: ; @true` — kernel-test ships no release artifact (test harness, not a library).
- `ci-branch: lint programs ci-test` — 5-min PR gate. Native `lint` is already fast; `programs` builds the test binaries for 3 architectures (fast with ccache); `ci-test` runs the framework self-tests.
- `ci-patch: ci-test` — post-merge smoke, framework-only.
- `ci-release` — prints a note; kernel-test deploys via homelab's `make deploy-kernel-test`, not a release tier.
- `ci-nightly: ci-nightly-body` → `smoke` — tinyconfig + kunitconfig kernel smoke (the native `smoke` target). SH-024 extends.

---

## Alternatives rejected

- **Override `build` and `test` directly in Makefile** instead of bypassing them in `ci-*` tier bodies. Would change what `make build` + `make test` mean for interactive use — breaks developer muscle memory and docs. The `.shepherd.yml` change isolates the semantic shift to shepherd's runs only.
- **Drop the shepherd-contract snippet via `include`** — forces a new file + expands to ~100 lines of timing-wrapper boilerplate. The direct targets below are 30 lines and reuse the natives already battle-tested.
- **Defer this PR until SH-024 (artifact-cache-keyed nightly) ships** — mixes contract adoption with behaviour change. SH-019 is minimum-viable; SH-024 is a separate story.

---

## Breaking changes

- `.shepherd.yml` now points at `make programs` + `make ci-test` instead of `make` + `make test`. Only affects shepherd's reusable workflow runs; no consumer-visible impact.

---

## Testing strategy

Verified by:

- `make -n <each-contract-target>` produces a sensible plan (verified locally, no kernel tree present).
- Interactive `make build` / `make test` / `make programs` / `make smoke` / `make ci-test` unchanged — grepped for conflict; no overlapping definitions.
- Shepherd's next SH-017 `--verify-contract` run will confirm compliance.

---

## Testing commands

```sh
make -n build            # → programs
make -n test             # → unchanged (heavy — kernel tree required)
make -n test-affected    # → ci-test
make -n smoke            # → unchanged (tinyconfig + kunitconfig)
make -n release-artifacts  # → true
make -n ci-branch        # → lint + programs + ci-test
make -n ci-patch         # → ci-test
make -n ci-release       # → echo n/a
make -n ci-nightly       # → smoke
```

---

## Rollout

Merge to `main` → no production action required. Next PRs on this track:

- **SH-024** (shepherd) — kernel-test ci-nightly with `(kernel_ref, config_hash, toolchain)`-keyed artifact cache.
- **SH-017** (shepherd) — `shepherd-bump --verify-contract` — will pass on kernel-test once merged.
