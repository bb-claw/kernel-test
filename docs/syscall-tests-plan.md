# Syscall Tests — Plan

Branch: `feat/syscall-tests`
Start date: 2026-08-10

---

## Situation

The test suite has 43 tests (slots 001–410). Findings from `kernel-test-data/FINDINGS.md`
reveal recurring patterns — 32-bit truncation bugs, io_uring regressions, seccomp/landlock
enforcement failures — that are not exercised by any current test. Adding six new test slots
(420–470) closes these gaps and gives each -rc kernel a broader in-VM functional baseline.

---

## Problems to Solve

1. **32-bit truncation class not tested** — FINDINGS.md documents gpu_buddy `roundup_pow_of_two`
   and REED_SOLOMON_DEC16 GF(2^16) truncating 32-bit intermediate values. No current test
   exercises large-offset file I/O or large mmap on i386 to catch userspace manifestations.

2. **seccomp not tested** — seccomp-filter is a critical security primitive; a regression
   silently breaking `SECCOMP_MODE_FILTER` or `seccomp(2)` would go undetected.

3. **io_uring not tested** — io_uring is the dominant async I/O path; SQE/CQE round-trip
   failures and kernel regressions in the submission path have no current canary.

4. **fd-based IPC primitives not tested** — timerfd/eventfd/signalfd are widely used
   abstractions. Their kernel implementations share state-machine code that regresses
   independently of network tests.

5. **Unix sockets not tested** — `CONFIG_UNIX` sockets are used by virtually every
   userspace daemon. The current network test only exercises `lo` ping (IP stack).

6. **Landlock enforcement not tested** — FINDINGS.md shows a GCC 16 landlock build error
   (`uninitialized struct` in `is_access_to_paths_allowed`). A runtime test that creates
   a ruleset and verifies `open()` is blocked catches enforcement regressions early.

---

## Goals

1. Add `tests/programs/syscall-tests/` — a single cross-compiled binary with subcommands,
   one per test family (32bit, seccomp, io_uring, fds, unix, landlock).
2. Add six test scripts (420_–470_) that invoke the binary and skip gracefully when the
   required kernel config or syscall is absent.
3. Add `tests/ci/test-syscall-tests.sh` that builds the binary for x86_64 and i386 and
   runs each subcommand on the host.
4. All 49 tests pass on `make smoke` (kunitconfig + tinyconfig × 4 archs).
5. Wire into `lib/initramfs.sh` and `lib/bootstrap.sh`.

---

## Scope

Files/components changed:
- `tests/programs/syscall-tests/syscall-tests.c` — new C program with subcommands
- `tests/programs/syscall-tests/Makefile` — cross-compile for 4 arches, clang gate x86_64
- `tests/programs/Makefile` — add `syscall-tests` to recursive `make all`
- `tests/custom/420_32bit-boundary.sh` — 32-bit lseek + mmap boundary test
- `tests/custom/430_seccomp.sh` — seccomp filter enforcement
- `tests/custom/440_io-uring.sh` — io_uring SQE/CQE round-trip
- `tests/custom/450_fd-ipc.sh` — timerfd + eventfd + signalfd
- `tests/custom/460_unix-socket.sh` — AF_UNIX stream + datagram
- `tests/custom/470_landlock.sh` — landlock ruleset + open() enforcement
- `lib/initramfs.sh` — inject syscall-tests binary at `usr/bin/syscall-tests`
- `lib/bootstrap.sh` — build syscall-tests after arena-test
- `memory/test-inventory.md` — add 6 new rows, update next slot to 480_
- `memory/project.md` — update test count and current state

No changes to: configs/, existing test scripts, report/vm/build pipeline.

---

## Non-goals

- No kernel module changes (all tests are pure userspace syscall invocations).
- No new capability markers (binary always injected; subcommands skip at runtime).
- No arm64/riscv CI coverage (cross-compilers may not be present on CI host; x86_64+i386 only).
- No performance benchmarking — tests verify correctness only (pass/fail).

---

## Design Decisions

### Single binary with subcommands

Like the ns-* pattern, all syscall families share one compiled binary
(`syscall-tests <subcommand>`). Avoids six separate build targets, six separate
`install_program_binary` calls, and six separate initramfs slots. Each subcommand
is a standalone function; the dispatcher is a simple `strcmp` chain.

### Always inject, skip at runtime

No `/tests/syscall-enabled` capability marker. The binary is always present (it has
no external runtime deps beyond libc). Individual subcommands call `syscall()` and
check `ENOSYS`/`EACCES`/`EPERM` and emit `skip:` accordingly. This mirrors
`arena-test` (always present, internal skip) rather than `perf-event` (marker gate).

### 32-bit boundary: both lseek >4 GB and large mmap

lseek >4 GiB on a sparse tmpfs file tests `off_t` sign-extension in the VFS layer.
Large anonymous mmap tests `vm_area_struct` address arithmetic. Both classes appear
in FINDINGS.md (`roundup_pow_of_two` truncation). Tests skip on non-i386 where the
32-bit truncation class is not relevant, and on tinyconfig where tmpfs may be absent.

### Landlock scope: basic enforcement

Create a ruleset, add a `LANDLOCK_RULE_PATH_BENEATH` rule for `/tmp`, restrict the
process, then verify `open("/etc/passwd", O_RDONLY)` returns `EACCES`. This is the
minimal useful test. No nested landlock or multi-layer rules.

### io_uring depth: medium (ring setup + read/write + SQE/CQE round-trip)

`io_uring_setup(8, &params)` → populate one IORING_OP_READ SQE → submit →
`io_uring_enter(1, 1)` → read one CQE → verify `res >= 0`. No liburing dependency;
raw `io_uring_setup(2)` + mmap of SQ/CQ rings. Gracefully skips on `ENOSYS` or
`EPERM` (restricted `io_uring_disabled` sysctl).

---

## Testing strategy

- **420_ on tinyconfig/i386** — lseek >4 GB requires tmpfs; skip if `/tmp` is not tmpfs.
  mmap test is always runnable; guard with `[ -f /proc/sys/vm/overcommit_memory ]`.
- **430_ seccomp** — check `/proc/sys/kernel/seccomp` or attempt `seccomp(2)` + ENOSYS skip.
- **440_ io_uring** — `io_uring_setup(2)` → ENOSYS or EPERM → skip.
- **450_ fd-ipc** — timerfd/eventfd/signalfd always available when the binary runs (no config gate).
- **460_ unix** — `socket(AF_UNIX, ...)` → EAFNOSUPPORT → skip.
- **470_ landlock** — `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)` →
  ENOSYS → skip; skip also when ABI version < 1.

- **CI (test-syscall-tests.sh)** — builds for x86_64 and i386; runs each subcommand; verifies
  exit 0 or correct `SKIP:` output on host (host kernel may not have io_uring enabled).

---

## Testing commands

```sh
# 1. Build the binary
make -C tests/programs/syscall-tests

# 2. Clang quality gate (x86_64)
make -C tests/programs/syscall-tests bin/x86_64/syscall-tests-clang

# 3. CI test
make ci-test  # runs tests/ci/test-syscall-tests.sh

# 4. In-VM smoke (kunitconfig + tinyconfig, all 4 archs)
make smoke NO_FETCH=1

# 5. Full 8-combo verification
make all NO_FETCH=1 CONFIGS=tinyconfig
# Expected: PASS 49/49 (or skip where syscall absent)
```
