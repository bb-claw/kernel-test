# fix: three high-severity Toybox sh bugs — Plan

Branch: `fix/pipe-elif-cr-nofork`
Start date: 2026-08-27

---

## Situation

Three high-severity bugs were identified during a systematic code review (FINDINGS.md,
2026-08-26). All three stem from documented Toybox sh pitfalls (code-quality.md) that
were introduced before the pitfall list was codified. Two cause incorrect test results
on every run; one silently negates the coverage value of a test.

---

## Problems to Solve

1. **`170_pipe.sh` false FAIL** — Two Toybox bugs compound: the `elif` double-execution
   bug clears `_large_src` after setting it; the `$_varname` bug then makes the guard
   pass with a literal string, causing `head -c` to try opening a file named `large_src`.
   Result: 1 MiB pipe test always reports FAIL on defconfig/kunitconfig/randdefconfig.

2. **`\r` in FAILED_TESTS** — QEMU serial output has `\r\n` endings. KUnit counting
   strips `\r` but the `FAILED_TESTS` extraction pipeline does not. Every run with a
   failing test writes `\r`-embedded test names to `vm.status`, corrupting terminal
   output, `summary.txt`, and `summary.mail.txt` sent to LKML.

3. **`150_mmap.sh` NOFORK gap** — `sh -c 'exit 0'` (bare `sh`) is a NOFORK builtin in
   Toybox 0.8.11+. No fork/exec occurs; the VMA-stability assertion is trivially true.
   The test claims to verify fork+exec VMA behaviour but tests nothing of the sort.

4. **`500_sysvipc` ENOSYS on tinynsconfig/i386** — musl's `semop()` routes through
   `SYS_ipc(SEMTIMEDOP=4)`. On 32-bit kernels, that subcommand requires
   `CONFIG_COMPAT_32BIT_TIME` (which depends on `CONFIG_POSIX_TIMERS`). tinyconfig
   has `CONFIG_POSIX_TIMERS=n`, so `semop` returns ENOSYS even though `CONFIG_SYSVIPC=y`.
   Found during ns-smoke validation of this branch.

---

## Goals

1. `170_pipe.sh` produces `ok: 1 MiB through pipe intact` on defconfig x86_64 (no false FAIL)
2. `vm.status FAILED_TESTS` and `summary.txt` contain no `\r` characters when tests fail
3. `150_mmap.sh` performs an actual `fork()+exec()` before measuring VMA stability
4. CI catches future regressions of all three bug classes via static checks + fixture tests
5. `500_sysvipc` passes (or skips cleanly) on tinynsconfig/i386 — no false FAIL from semop ENOSYS

---

## Scope

Files changed:
- `tests/custom/170_pipe.sh` — replace `elif+else` with nested `if/else/fi`; rename
  `_large_src` → `large_src` to remove leading-underscore variable bug
- `lib/common.sh` — add `s/\r//` to `FAILED_TESTS` sed pipeline in `parse_serial_output`
- `tests/custom/150_mmap.sh` — change `sh -c 'exit 0'` to `/bin/sh -c 'exit 0'`
- `tests/ci/fixtures/parser/transcript-crlf-fail.txt` — new fixture: CRLF-terminated
  serial transcript with two failing tests; used by the `\r` regression test
- `tests/ci/test-vm-parser.sh` — add two test cases: CRLF transcript parses without
  `\r` in FAILED_TESTS; FAILED_TESTS contains the correct test names
- `tests/ci/test-toybox-pitfalls.sh` — new CI test: static grep checks across all
  `tests/custom/*.sh` for the three Toybox pitfall patterns (elif, `$_varname`,
  bare `sh` before `-c`)
- `tests/ci/coverage-map.md` — add entry for the new pitfalls CI test

Also changed (found during ns-smoke validation):
- `tests/programs/syscall-tests/syscall-tests.c` — skip semop ENOSYS in `test_sysvipc_sem`:
  on tinynsconfig/i386, `CONFIG_POSIX_TIMERS=n` means `SYS_ipc(SEMTIMEDOP)` returns ENOSYS
  even with `CONFIG_SYSVIPC=y`; skip rather than fail (accurate config-limitation report).
  Note: adding `CONFIG_POSIX_TIMERS=y` to namespaces.config was tried but rejected — it
  pulled in `CONFIG_PERF_EVENTS=y` as a side effect, causing 400_perf-events to fail on
  tinynsconfig/i386 where the full perf infrastructure is absent.

No changes to: Makefile, presets, config fragments, initramfs, lib/vm.sh, lib/report.sh,
lib/diff.sh, lib/install.sh, or any other test script.

---

## Non-goals

- Fixing the LOW-severity `040_check-devnodes.sh` elif bug (separate branch)
- Adding new kernel functionality tests
- Changing `030_check-dmesg.sh` (MEDIUM severity, separate branch)
- Suppressing Toybox pitfall patterns in lib/ scripts (lib/ uses bash, not Toybox sh;
  `elif` is safe there)

---

## Design decisions

### Fixture file encoding for CRLF test

The fixture `transcript-crlf-fail.txt` is written with actual CR+LF byte pairs using
`printf '...\r\n'`. Git may normalise line endings on checkout unless `.gitattributes`
marks the file as binary or with `eol=lf`. To be safe the fixture is written with an
explicit `eol=lf` attribute so git does not modify it. Alternatively the test could
generate the fixture in a tmpdir — but a committed fixture makes the test self-contained
and readable in code review.

Actually, since `eol` gitattributes can be complex and the fixture is small, the test
generates the CRLF content in a tmpdir to avoid any git normalisation concern. The
fixture file in `tests/ci/fixtures/parser/` is kept LF-only (standard); the CRLF
variant is produced at test time.

### Static checks scope: tests/custom/ only

The `elif`, `$_varname`, and bare-`sh` checks are enforced only on `tests/custom/*.sh`
and `tests/001_smoke.sh`. Lib scripts (`lib/`) and CI scripts (`tests/ci/`) use bash
and are not subject to Toybox sh constraints. The pre-push hook runs shellcheck on
lib/ scripts separately.

### `elif` ban is total within test scripts

Any `elif` in a VM test script is a latent Toybox 0.8.9 bug (both branches execute
when the first condition is true). The static check therefore flags any `elif` occurrence
rather than trying to detect the specific double-execution pattern. False positives
(benign `elif` that happens to be unreachable) are not expected given the pitfall
documentation; contributors are expected to use nested `if/else/fi` instead.

---

## Testing strategy

- **Bug 1 (`170_pipe.sh`)** — run `make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64`
  and verify `ok: 1 MiB through pipe intact` in vm output. Static check in
  `test-toybox-pitfalls.sh` prevents reintroduction.

- **Bug 2 (`common.sh \r`)** — `test-vm-parser.sh` gains a test case that calls
  `parse_serial_output` on a CRLF-terminated transcript and asserts `FAILED_TESTS`
  contains no `\r`. Covers both the extraction and the write-to-vm.status path.

- **Bug 3 (`150_mmap.sh NOFORK`)** — run `make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64`
  and verify `ok: parent VMA table stable after fork/exec` still passes. Static check
  in `test-toybox-pitfalls.sh` prevents bare `sh -c` reintroduction.

- **Static checks** — `test-toybox-pitfalls.sh` verifies all three patterns are absent
  from `tests/custom/` after the fixes are applied. These checks become the regression
  gate for future contributors.

- **No CI kernel build** — the three test-script fixes are verified by `make dev-test`
  which runs the VM pipeline; no additional QEMU-level CI is needed.

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, ≥70% decision paths covered

make ci-test
# Expected: all tests/ci/test-*.sh pass including test-vm-parser.sh and
#           test-toybox-pitfalls.sh

# Verify bug 1 fix directly (requires a built defconfig kernel):
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64
# Expected: 170_pipe → ok: 1 MiB through pipe intact (was: FAIL: pipe data loss)

# Verify bug 2 fix: inspect vm.status FAILED_TESTS on a run with failures:
grep FAILED_TESTS build/defconfig-x86_64/vm.status | od -c | grep -v '\\r'
# Expected: no \r characters in any FAILED_TESTS value

# Verify bug 3 fix (no kernel build needed — static):
grep -n 'sh -c' tests/custom/150_mmap.sh
# Expected: /bin/sh -c 'exit 0'
```
