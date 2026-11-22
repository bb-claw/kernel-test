# Test Programs Quality Hardening — Plan

Branch: `feat/programs-quality`
Start date: 2026-08-09

---

## Situation

`arena-test` and `perf-event` were written before the C compilation baseline was
established by PR #49 (serial-capture hardening). They compile with inconsistent
warning flags, no Clang quality-gate, and no CI tests. `arena-test` also has
debug printf calls that appear unguarded in VM serial output.

---

## Problems to Solve

1. **Inconsistent CFLAGS** — `perf-event` uses only `-Wall`; `arena-test` mixes warning
   flags into per-arch variables instead of using `CFLAGS_COMMON`/`CFLAGS_COMMON_GCC`.
2. **No Clang quality gate** — neither program is compiled with `-Weverything -Werror`
   to catch sign-conversion, unsafe buffer usage, and similar issues.
3. **Noisy VM serial output** — `arena-test` prints `*** TEST: ...` and
   `arena_print_with_blocks()` diagnostics unconditionally, cluttering the serial log.
4. **No CI tests** — no build-verification or behavioral CI tests for either program.
5. **No top-level programs Makefile** — bootstrap.sh calls each program's Makefile
   separately; no single `make -C tests/programs` entry point.
6. **`perf-event` uses `gcc` for x86_64** — inconsistent with the musl-gcc baseline.

---

## Goals

1. Both programs compile clean under `CFLAGS_COMMON_GCC` (`-Wall -Wextra -Wpedantic -Werror`)
   and `CFLAGS_COMMON_CLANG` (`-Weverything -Werror` + explicit suppressions) for x86_64.
2. `arena-test` debug output gated behind `VERBOSE=1` environment variable at runtime.
3. `tests/ci/test-arena-test.sh` and `tests/ci/test-perf-event.sh` pass on CI (x86_64
   build + behavioral run of static binary; cross-arches skipped when compiler absent).
4. `tests/programs/Makefile` top-level target builds arena-test + perf-event + serial-capture.
5. `perf-event` uses musl-gcc for x86_64 (consistent with the baseline).
6. `perf-event.c` uses `-std=c11` if the Linux UAPI headers permit it; `gnu11` documented
   as a known exception if not.

---

## Scope

Files changed:
- `tests/programs/arena-test/arena-test.c` — VERBOSE guard, remove commented-out code,
  replace `arena_print_with_blocks` after `arena_destroy` with `arena_print`
- `tests/programs/arena-test/Makefile` — CFLAGS_COMMON baseline, musl-clang x86_64 gate
- `tests/programs/perf-event/perf-event.c` — attempt c11; update if UAPI headers require gnu11
- `tests/programs/perf-event/Makefile` — CFLAGS_COMMON baseline, musl-gcc x86_64, musl-clang gate
- `tests/programs/Makefile` — new top-level: arena-test + perf-event + serial-capture
- `tests/ci/test-arena-test.sh` — new CI test
- `tests/ci/test-perf-event.sh` — new CI test
- `memory/project.md` — status update
- `memory/code-quality.md` — update C baseline note

No changes to: VM test scripts (410_arena-memory.sh, 400_perf-events.sh), initramfs.sh,
bootstrap.sh (existing make -C calls still work; top-level Makefile is additive).

---

## Non-goals

- Clang cross-compilation for arm64/riscv/i386 — requires sysroot packages not in bootstrap.
- Rewriting arena-test tests or adding new VM-level test cases.
- ASAN/TSAN instrumented builds.

---

## Design decisions

### CFLAGS structure (same as serial-capture baseline)

```
CFLAGS_COMMON       := -std=c11 -O2 -D_DEFAULT_SOURCE \
                       -Wno-declaration-after-statement \
                       -Wno-implicit-function-declaration
CFLAGS_COMMON_GCC   := -Wall -Wextra -Wpedantic -Werror
CFLAGS_COMMON_CLANG := -Weverything -Werror \
                       -Wno-disabled-macro-expansion \
                       -Wno-unsafe-buffer-usage
```

Per-arch CFLAGS hold only arch-specific flags (`-static`, `-m32`), not warning flags.

### Shipped binary = GCC; Clang = quality gate only

Cross-compiled binaries (arm64, riscv, i386) use their respective GCC cross-compilers.
The Clang quality gate applies only to x86_64 via musl-clang (host compiler available
everywhere `make bootstrap` runs). The shipped binary for all arches is the GCC build.

### VERBOSE via getenv()

`getenv("VERBOSE")` checked once at the top of `main()`; result stored in a static int.
No recompile needed to toggle; set `VERBOSE=1` before running for local debugging.
CI and VM runs see no debug output by default.

### perf-event c11 vs gnu11

Attempt `-std=c11 -D_DEFAULT_SOURCE` first. Linux UAPI headers (`<linux/perf_event.h>`)
define their own `__u64` types independently of glibc/musl; `syscall()` is available
under `_DEFAULT_SOURCE`. If a compiler error appears, fall back to `gnu11` and document
it in `code-quality.md`.

### CI behavioral test for x86_64

The static musl-gcc x86_64 binary runs on the CI host. arena-test behavioral test checks
all `key=value` lines and verifies `overall=PASS`. perf-event behavioral test checks
exit 0 and numeric output > 0; skips with a notice if `perf_event_open` is restricted
by `kernel.perf_event_paranoid`.

---

## Testing strategy

- **Build (x86_64 GCC + Clang)** — `make -C tests/programs/arena-test` and `make -C tests/programs/perf-event`; zero warnings, both binaries produced.
- **Behavioral (arena-test x86_64)** — run binary on CI host; assert `overall=PASS` and presence of all 6 result keys.
- **Behavioral (perf-event x86_64)** — run binary on CI host; assert exit 0 and numeric output; soft-skip if syscall restricted.
- **Cross-compile** — verified locally; CI skips arm64/riscv/i386 when cross-compilers absent.
- **VM** — existing 400_perf-events.sh and 410_arena-memory.sh continue to pass unchanged.

---

## Testing commands

```sh
# 1. Build both programs (requires musl-gcc, musl-clang, aarch64-linux-gnu-gcc, riscv64-linux-gnu-gcc)
make -C tests/programs/arena-test clean all
make -C tests/programs/perf-event  clean all

# 2. Top-level convenience target
make -C tests/programs clean all

# 3. CI test suite (x86_64 only)
bash tests/ci/test-arena-test.sh
bash tests/ci/test-perf-event.sh

# 4. Behavioral smoke (arena-test x86_64 with verbose output)
VERBOSE=1 tests/programs/arena-test/bin/x86_64/arena-test

# 5. Tier 2 CI
make ci-test
```
