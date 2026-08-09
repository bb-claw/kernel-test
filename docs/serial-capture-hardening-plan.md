# serial-capture Hardening — Plan

Branch: `feat/serial-capture-hardening`
Start date: 2026-08-09

---

## Situation

`tests/programs/serial-capture/serial-capture.c` is the host-side UART capture binary
used by `lib/board.sh` for all hardware test runs. It works correctly but carries
technical debt from its initial implementation: `signal()` with implicit `SA_RESTART`
forces a 100ms polling workaround (VMIN=0, VTIME=1), `atoi()` does no error checking,
and the Makefile uses an ad-hoc `musl-clang` invocation with no GCC counterpart.

---

## Problems to Solve

1. **`signal()` + VMIN=0 workaround** — `signal()` on Linux sets `SA_RESTART`,
   which causes `read()` to restart after SIGTERM instead of returning EINTR.
   The workaround (VMIN=0, VTIME=1) polls every 100ms to check `running`. This
   delays shutdown by up to 100ms and obscures the real design intent.

2. **`atoi()` with no error checking** — a non-numeric or out-of-range baud
   argument silently returns 0, producing a misleading "unsupported baud rate: 0"
   error rather than flagging the actual invalid input.

3. **Makefile: single-compiler, undocumented flags** — only Clang/musl is built.
   GCC is never exercised. The commented-out `-Weverything` flag is not active.
   There is no shared flag structure that other `tests/programs/` Makefiles can
   adopt as a baseline.

4. **No CI tests for the binary itself** — `test-board-serial.sh` tests `board.sh`
   (the Bash layer), not `serial-capture` directly. Behavioral properties (data
   integrity, SIGTERM latency, baud rejection) are untested.

---

## Goals

1. Replace `signal()` with `sigaction()` (SA_RESTART cleared); switch to
   VMIN=1 / VTIME=0 — SIGTERM interrupts `read()` with EINTR immediately.
2. Replace `atoi()` with `strtol()` with full error checking.
3. Add B460800, B921600, B1000000, B1500000 to `baud_to_speed()`.
4. Compile with both `musl-gcc` and `musl-clang`; both must produce zero warnings
   with the flag sets below; only the Clang binary is installed.
5. `CFLAGS_COMMON`, `CFLAGS_COMMON_GCC`, `CFLAGS_COMMON_CLANG` — the reference
   pattern that all future `tests/programs/` Makefiles will follow.
6. `tests/ci/test-serial-capture.sh` — new CI test covering build verification,
   data integrity (socat pty), SIGTERM latency, and baud rejection.
7. `make bootstrap` installs `musl-tools` (Arch) / `musl-tools` (Debian); build
   fails with a clear error if `musl-gcc` or `musl-clang` is absent.

---

## Scope

Files changed:
- `tests/programs/serial-capture/serial-capture.c` — sigaction, strtol, baud table, casts
- `tests/programs/serial-capture/Makefile` — dual-compiler, CFLAGS baseline structure
- `tests/ci/test-serial-capture.sh` — new CI test file (4 test groups)
- `lib/bootstrap.sh` — add musl-tools to package installs; add musl-gcc/musl-clang
  to required-tool check

No changes to: `lib/board.sh` (SERIAL_CAPTURE path unchanged), `lib/initramfs.sh`,
arena-test, perf-event (left for a follow-up branch).

---

## Non-goals

- Updating arena-test or perf-event Makefiles to the new baseline (separate branch).
- Cross-compiling serial-capture for non-x86_64 (host-only tool).
- Adding POSIX compliance annotations or replacing `cfmakeraw()` with explicit flag
  manipulation (cfmakeraw is available on all supported hosts via `_DEFAULT_SOURCE`).

---

## Design decisions

### sigaction() + VMIN=1 / VTIME=0

`sigaction()` with `sa_flags = 0` (SA_RESTART absent) means SIGTERM causes
`read()` to return -1/EINTR immediately. The existing `errno == EINTR → continue`
path then checks `running == 0` and exits the loop without any polling latency.

VMIN=1 / VTIME=0: `read()` blocks until at least one byte arrives. This is the
correct semantic for a capture loop — we want to process data as it arrives, not
poll every 100ms. On EOF (device disconnected or pty peer closed), `read()` returns 0;
the loop breaks cleanly.

The VMIN=0 / VTIME=1 workaround and its explanatory comment are removed.

### Compiler flag structure

```
CFLAGS_COMMON          -std=c11 -O2 -D_DEFAULT_SOURCE
                       -Wno-declaration-after-statement
                       -Wno-implicit-function-declaration

CFLAGS_COMMON_GCC      -Wall -Wextra -Wpedantic -Werror

CFLAGS_COMMON_CLANG    -Weverything -Werror
                       + documented suppressions (see below)
```

`CFLAGS_COMMON` suppressions:
- `-Wno-declaration-after-statement`: C11 permits mixed declarations; used project-wide
  in all test programs for readability; not a safety concern.
- `-Wno-implicit-function-declaration`: guard against missing-include regressions in
  future edits; also suppressed project-wide.

`CFLAGS_COMMON_CLANG` suppressions (Clang-specific; documented inline in Makefile):
- `-Wno-disabled-macro-expansion`: musl defines `stderr` as a self-referential macro
  (`#define stderr (stderr)`); Clang's `-Weverything` fires on every `fprintf(stderr…)`.
  This is a musl implementation detail, not a code defect.
- `-Wno-unsafe-buffer-usage`: Clang 16+ fires on `argv[N]` indexing and `buf + off`
  pointer arithmetic that are demonstrably bounds-correct. No safer alternative API
  exists for these patterns in C11.

GCC required no suppressions beyond `CFLAGS_COMMON` (clean with `-Wall -Wextra -Wpedantic`).

### Sign-conversion fix in cflag manipulation

`~CSTOPB`, `~CRTSCTS`, and `(CLOCAL | CREAD)` are `int` constants. Assigning them
to `c_cflag` (type `tcflag_t = unsigned int`) triggers `-Wsign-conversion`. Fixed
with explicit `(tcflag_t)` casts — a code fix, not a suppression.

### musl hard-required

`musl-gcc` and `musl-clang` are required tools; `make bootstrap` installs `musl-tools`.
No glibc-static fallback: the binary is shipped to users and musl produces a self-
contained statically linked binary with minimal size and no glibc version dependency.
A clear bootstrap error message is preferable to a silent degradation.

### Baud rate table

B460800, B921600, B1000000, B1500000 added proactively. These are standard Linux
termios constants available on all supported kernels (≥ 2.6). The previous table
(max 230400) limits hardware support unnecessarily; the additions are zero-risk
(they are plain `case` entries in a `switch`).

### CI tests

New file `tests/ci/test-serial-capture.sh` with four groups:

| Group | What | How |
|---|---|---|
| `sc-build` | Both compilers compile with zero warnings | `make -C ... clean all` |
| `sc-behavior-data` | Bytes written to pty appear verbatim in logfile | socat pty pair + `printf` on tx + SIGTERM |
| `sc-sigterm-latency` | SIGTERM exits within 1s (sigaction, no VTIME polling) | socat pty pair, SIGTERM, poll for exit |
| `sc-baud-rejection` | Invalid baud arg → non-zero exit + stderr message | call binary with `abc` or `99` |

socat is already a CI dependency (test-board-serial.sh uses it). Skip groups 2–3
when socat is absent (pass group 1 independently).

---

## Testing strategy

- **Build**: CI runs `make clean all` in the serial-capture directory; both GCC
  and Clang compile with zero warnings → CI pass.
- **Behavioral**: socat pty pair; `printf` writes 256 known bytes to tx; serial-capture
  reads them to logfile; SIGTERM; verify logfile content with `cmp`.
- **SIGTERM latency**: start on idle pty; SIGTERM; verify exit within 1s.
- **Baud rejection**: invalid arg → non-zero exit.
- **Integration**: `test-board-serial.sh` exercises board.sh → serial-capture path
  end-to-end (unchanged).

---

## Testing commands

```sh
# 1. Build verification: both compilers, zero warnings
make -C tests/programs/serial-capture clean all
# Expected: exit 0, no warning lines

# 2. Run new CI tests
bash tests/ci/test-serial-capture.sh
# Expected: N passed, 0 failed

# 3. Full CI suite (must stay clean)
make ci-test
# Expected: all tests pass

# 4. Board smoke (integration path)
make hw-test BOARD_TTY=/dev/ttyUSB0
# Expected: 43/43 PASS (requires hardware)
```
