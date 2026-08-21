# valgrind tests for C programs — Plan

Branch: `feat/valgrind-tests`
Start date: 2026-08-21

---

## Situation

All five C programs in `tests/programs/` are compiled with GCC (`-Wall -Wextra -Wpedantic -Werror`)
and Clang (`-Weverything -Werror`) against musl. Static analysis catches type and API misuse,
but not runtime memory errors: buffer overruns, use-after-free, uninitialised reads, and leaks.
Valgrind fills this gap with zero code changes to the programs themselves.

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

No changes to: the C source files themselves, the VM pipeline, CI tests, the shipped binaries.

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
that differ from glibc's. Rather than writing suppressions for musl internals, a glibc build
(`gcc`, no `-static`) gives clean output. Flags: `-g -O1 -D_DEFAULT_SOURCE` plus the same
`-Wall -Wextra -Wpedantic -Werror` quality gate. `-O1` is preferred over `-O0` — it keeps
inlining minimal so stack frames are still legible, while not interfering with variable
lifetime tracking the way `-O2` can.

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

`tests/programs/valgrind.supp` suppresses known false positives from glibc's dynamic linker
(`dl_init`, `_dl_catch_exception`), `getenv`, and libc startup (`__libc_start_main`). These
are well-known and reproducible across glibc versions. All suppressions include a comment
explaining which glibc internal they cover.

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
# Expected: PASS for all 5 programs (or skip for unavailable syscalls); exit 0

# Inject a bug to verify detection
# Edit arena-test.c: write one byte past the arena end; re-run make valgrind
# Expected: FAIL for arena-test; exit 1

make lint
# Expected: shellcheck clean, no size violations
```
