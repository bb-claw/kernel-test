---
id: KT-001
slug: toybox-revert-0814
status: shipped        # draft → ready → in-progress → shipped
created: 2026-11-28
owner: "@bb-claw"
branch: "fix/KT-001-toybox-revert-0814"
plan: "docs/plans/KT-001-toybox-revert-0814-plan.md"
---

# KT-001 — Revert Toybox pin to 0.8.14 (0.8.15 hangs VM tests)

For anyone running the harness: Toybox 0.8.15 was pinned by
`chore/bump-toybox-0.8.15`, but 0.8.15 deadlocks the in-VM test run. Every
`kunitconfig` boot hangs at `030_check-dmesg`, independent of the kernel under
test. Revert the pin to the known-good 0.8.14 so boot tests complete again.

## 1. Who is the operator/user?

A kernel maintainer/tester running `make all` (or `make smoke`/`ns-*`) to verify
an -rc or stable kernel. They read the hang as a *kernel* failure and waste time
bisecting the kernel when the real cause is the userland binary.

## 2. When does the story fire?

Any VM test run whose kernel log exceeds ~64 KB (always true for `kunitconfig`:
KUnit output alone is ~95 KB). Test `030_check-dmesg` pipes the log through
`printf '%s\n' "$KLOG" | grep …`; under 0.8.15 the run freezes there.

## 3. What does success look like?

`make all NO_FETCH=1 CONFIGS=kunitconfig ARCHS=arm64` boots, runs all 52 tests,
reaches `TEST_DONE`, and reports PASS — on both 7.3.6 and 7.3.7-rc1. The pinned
version is 0.8.14 everywhere the harness selects Toybox.

## 4. How urgent?

- [x] Critical (correctness, regression, security)
- [ ] High (workflow blocker, significant quality loss)
- [ ] Normal (enhancement, new feature)
- [ ] Low (nice-to-have, polish)

## 5. Happy path

```
make all NO_FETCH=1 CONFIGS=kunitconfig ARCHS=arm64
# Expect: "Initramfs ready" (toybox-aarch64 = 0.8.14), boot OK,
#         tests 52/52, kunit 260/260, Overall result: PASS, exit 0
```

## 6. Edge cases / failure modes

- Stale cached 0.8.15 binary: `lib/download-toybox.sh` sees the version stamp
  mismatch (`0.8.15 → 0.8.14`) and re-downloads automatically — no manual
  `cache/` cleanup required.
- Offline host with no cached 0.8.14: `download-toybox.sh` dies with a clear
  "Download failed … check network or TOYBOX_VERSION" message (pre-existing).

## 7. Out of scope

- Hardening `030_check-dmesg` to avoid the >64 KB builtin-to-pipe pattern
  (tracked separately — this story is strictly the version revert).
- Diagnosing/fixing the Toybox 0.8.15 `sh` pipe bug upstream.
- `scripts/config-bisect.sh`'s independent `:-0.8.9` default (legacy, unrelated).

## 8. Acceptance criteria (Gherkin)

```gherkin
Scenario: kunitconfig boots on the reverted pin
  Given TOYBOX_VERSION is pinned to 0.8.14
  When  make all NO_FETCH=1 CONFIGS=kunitconfig ARCHS=arm64 runs
  Then  the run reaches TEST_DONE with 52/52 tests passed
  And   the Overall result is PASS (exit 0)

Scenario: pin is consistent across selection points
  Given the Makefile, lib/bootstrap.sh and lib/download-toybox.sh defaults
  When  make ci-test runs tests/ci/test-makefile-defaults.sh
  Then  TOYBOX_VERSION reads 0.8.14 in every location and the check passes
```

## 9. Capability / verification

No new capability id. Mechanically verified by the existing CI test
`tests/ci/test-makefile-defaults.sh` (asserts the Makefile pin and its
consistency with `lib/bootstrap.sh`) plus the happy-path boot in §5.
