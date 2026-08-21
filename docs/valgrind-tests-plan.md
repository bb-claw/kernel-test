# valgrind tests for C programs — Plan

Branch: `feat/valgrind-tests`
Start date: 2026-08-21

---

## Situation

All five C programs in `tests/programs/` are compiled with GCC (`-Wall -Wextra -Wpedantic -Werror`)
and Clang (`-Weverything -Werror`) against musl. Static analysis catches type and API misuse,
but not runtime memory errors: buffer overruns, use-after-free, uninitialised reads, and leaks.
Valgrind fills this gap. The first run also surfaced two real code bugs in `syscall-tests.c`
(fixed in this branch): an undersized BPF attr struct and an uninitialised `msgsnd` buffer.

---

## Problems to Solve

1. **No runtime memory safety check** — `arena-test` exercises a custom allocator; a
   buffer-overrun in the arena logic would pass static analysis and only manifest under Valgrind.
2. **No leak detection** — programs that open `/proc` files or allocate state for syscall setup
   may leak on error paths without any compile-time signal.
3. **Musl obscures Valgrind output** — musl static binaries produce `strlen`/`memset` noise in
   Valgrind output. A separate glibc build gives clean, actionable reports.

---

## Goals

1. Each program builds a `-valgrind` variant (glibc, `-g -O1`) via `make valgrind` in its own dir.
2. `make valgrind` at the repo root builds all five variants and runs each under Valgrind.
3. Any memory error or leak causes a non-zero exit; `make valgrind` exits non-zero if any program fails.
4. ENOSYS/skip exit codes from `perf-event` and `syscall-tests` subcommands count as pass.
5. `serial-capture` is exercised via a PTY pair (socat); exercises the argument-parse + open + read path.
6. Valgrind logs saved to `valgrind/<name>-<date>.log` (gitignored directory).
7. A shared `tests/programs/valgrind.supp` covers known glibc-internal false positives.
8. `make bootstrap` installs `valgrind` on Arch (pacman), Debian/Ubuntu (apt), and dnf/zypper.

---

## Scope

Files/components changed:
- `tests/programs/arena-test/Makefile` — add `valgrind` build target
- `tests/programs/perf-event/Makefile` — add `valgrind` build target
- `tests/programs/syscall-tests/Makefile` — add `valgrind` build target
- `tests/programs/snapshot/Makefile` — add `valgrind` build target
- `tests/programs/serial-capture/Makefile` — add `valgrind` build target
- `tests/programs/valgrind.supp` — shared Valgrind suppressions (new file)
- `scripts/valgrind.sh` — orchestration script (new file)
- `lib/bootstrap.sh` — add `valgrind` to all four package managers
- `Makefile` — add `make valgrind` target, add `valgrind/` to `.gitignore` export, help text, variable list
- `.gitignore` — add `valgrind/`
- `memory/workflows.md` — document `make valgrind`
- `memory/code-quality.md` — document C program Valgrind baseline

C source changes: `tests/programs/syscall-tests/syscall-tests.c` — two real bug fixes found
during first Valgrind run (see Design decisions). No changes to: the VM pipeline, CI tests,
or the shipped musl binaries.

---

## Non-goals

- Valgrind in GitHub Actions CI — too slow, too platform-specific
- ARM64/riscv Valgrind — not cross-Valgrind-able; host is x86_64 only
- Per-program suppressions — one shared file is sufficient for glibc noise
- Valgrind with musl — noisy; glibc build is the right tool for this

---

## Design decisions

### Separate glibc build (`-valgrind` variant)

Musl static binaries trigger Valgrind noise from internal `strlen`/`memcpy` implementations
that differ from glibc's. A glibc build gives clean, actionable reports.

The build uses `-static` (not a dynamic glibc link). Arch Linux's `ld-linux-x86-64.so.2`
(glibc 2.44) is stripped; Valgrind 3.25 cannot redirect `memcmp` in the dynamic linker and
aborts at startup with a fatal error. Static linking bypasses `ld.so` entirely.

Flags: `-g -O1 -D_DEFAULT_SOURCE` plus the same `-Wall -Wextra -Wpedantic -Werror` quality
gate. `-O1` keeps inlining minimal so stack frames are legible, without interfering with
variable lifetime tracking the way `-O2` can.

### Bugs found during first run

Two real code bugs were discovered and fixed in this branch:

1. **`syscall-tests/bpf`** — `st_bpf_prog_attr` was defined with only 7 fields (40 bytes).
   Valgrind checks the full kernel `union bpf_attr` layout regardless of the `attr_size`
   argument passed to `bpf()`. Fields `prog_flags` (offset 44), `prog_ifindex` (64), and
   `expected_attach_type` (68) were stack-uninitialized. Fix: extend the struct to 72 bytes
   (add `kern_version`, `prog_flags`, `prog_name[16]`, `prog_ifindex`, `expected_attach_type`).

2. **`syscall-tests/sysvipc-msg`** — `msg.text[16]` had only 12 bytes set by `memcpy`; the
   trailing 4 bytes were uninitialized and passed to `msgsnd()`. Fix: add
   `memset(&msg, 0, sizeof(msg))` before setting fields.

### ENOSYS = skip for perf-event and syscall-tests

Both programs are designed to exit with a documented skip code when the required kernel feature
is absent (e.g., `io_uring` disabled, `perf_event_paranoid > 2`). The Valgrind wrapper treats
these exit codes as pass — the point is to check memory safety of the code path that *did* run,
not to fail because the kernel feature is unavailable on the test machine.

### serial-capture uses a socat PTY pair

`serial-capture` requires a real TTY (`tcgetattr`/`tcsetattr`). A plain pipe returns ENOTTY
before the read loop. `socat` creates a PTY pair: one end feeds test bytes, the other is the
device path passed to `serial-capture`. This exercises the open, baud-rate setup, and at least
one `read()` iteration — the code path where buffer bugs live. `socat` is already a bootstrap
dep on Debian; it is added to the Arch pacman install.

### Shared suppressions file

`tests/programs/valgrind.supp` suppresses 8 known glibc false positives, all `Memcheck:Cond`:

- `__strcmp_avx2`, `__strncmp_avx2`, `__strstr_sse2_unaligned` — SIMD string functions read
  past null terminators in 32-byte aligned chunks; result is derived only from bytes up to `\0`
- `__nss_module_allocate`, `__nss_action_parse`, `__nss_module_get_function` — NSS module
  loader (triggered by `getpwuid` in snapshot) does not zero-init internal state before use
- `free` in `arena_destroy` — glibc's `_int_free()` reads the adjacent chunk header in 32-byte
  SIMD loads, touching bytes not explicitly tracked by Valgrind
- `free` in `__dcigettext` — `perror()` triggers gettext/locale init which calls `free()` on
  lazily-allocated internal state that was never zero-init'd (affects perf-event, serial-capture)

All suppressions are scoped to the specific calling function where known. None suppress
entire categories; real use-after-free or leak errors in our code will still be reported.

### Build only on `make valgrind`

The `-valgrind` variants are glibc-linked and not useful outside this context. They are not
built by `make programs` (which builds musl/clang shipped binaries) and not injected into the
initramfs. `make valgrind` builds them fresh each time it is called.

---

## Testing strategy

- **`make valgrind`** — full end-to-end: builds all five variants and runs each under Valgrind
- **`make valgrind SNAPSHOT=0`** — N/A (SNAPSHOT is a dmesg variable, not relevant here)
- **Manual: introduce a bug** — add a one-liner buffer overrun to arena-test.c, verify Valgrind catches it, revert
- **`make lint`** — shellcheck on scripts/valgrind.sh; context size check on memory files
- **No CI test** — Valgrind is local-only; adding it to tests/ci/ would require Valgrind installed on the CI runner

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, ≥70% decision paths

make valgrind
# Expected: PASS=13 SKIP=1 FAIL=0 (perf-event skips when paranoid > 2); exit 0

# Inject a bug to verify detection
# Edit arena-test.c: write one byte past the arena end; re-run make valgrind
# Expected: FAIL for arena-test; exit 1

make lint
# Expected: shellcheck clean, no size violations
```
