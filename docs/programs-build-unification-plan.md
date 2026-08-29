# Programs Build Unification — Plan

Branch: `feat/programs-build-unification`
Start date: 2026-08-29

---

## Situation

`tests/programs/` contains five C programs (arena-test, perf-event, serial-capture,
snapshot, syscall-tests) each with a ~70-line Makefile that is nearly identical.
`tests/ns/` contains eight C programs with a separate Makefile using weaker quality
flags (`gnu11`, `-Wall` only, no Clang gate). Every change to the build standard
must be applied manually to each of the six Makefiles — a maintenance burden and a
drift risk. The shared code-quality baseline is also under-documented.

---

## Problems to Solve

1. **Six divergent Makefiles** — compiler flags, arch lists, and quality gates are
   duplicated across `tests/programs/*/Makefile` and `tests/ns/Makefile`.
   A standard upgrade (e.g., adding a new GCC warning) requires six edits and
   is easy to miss.

2. **`tests/ns/` uses weaker standards** — `gnu11`, `-Wall` only, no Clang quality
   gate, plain `gcc` for x86_64 instead of musl.

3. **`memory/code-quality.md` says `c11`** — all programs already use `-std=c17`;
   the documentation is stale.

4. **musl-gcc dependency for arena-test** — musl-gcc is used only for the x86_64
   GCC build of arena-test; kernel nolibc provides a zero-dependency alternative.

---

## Goals

1. One shared `tests/programs/common.mk` holds all compiler, flag, and arch logic;
   each program's `Makefile` is a thin wrapper (~10 lines).
2. `tests/ns/Makefile` uses `common.mk` for flag definitions (FLAGS_ONLY=1).
3. All programs and ns/ share the same C17 + maximum GCC warning set + Clang gate.
4. `arena-test` x86_64 compiles with plain `gcc` + kernel nolibc (no musl-gcc dep).
5. `tests/ci/test-programs-build.sh` verifies the shared structure.
6. `memory/code-quality.md` updated to reflect C17 and the shared Makefile.

---

## Scope

Files changed:
- `tests/programs/common.mk` — NEW: shared flag variables + build rules
- `tests/programs/arena-test/Makefile` — thin wrapper; nolibc for x86_64
- `tests/programs/perf-event/Makefile` — thin wrapper
- `tests/programs/serial-capture/Makefile` — thin wrapper with HOST_ONLY=1
- `tests/programs/snapshot/Makefile` — thin wrapper; preserves fmt target
- `tests/programs/syscall-tests/Makefile` — thin wrapper
- `tests/ns/Makefile` — FLAGS_ONLY=1 + own multi-binary rules; upgraded flags
- `tests/ci/test-programs-build.sh` — NEW: structural + compile CI test
- `tests/ci/test-ns-build.sh` — update assertions for ns/Makefile restructure
- `scripts/dev-test.sh` — add H1 to ci9_tests[]; update total_paths
- `tests/ci/coverage-map.md` — add H1 row
- `memory/code-quality.md` — fix c11→c17; add common.mk reference

No changes to: C source files, `.gitignore` files, `lib/bootstrap.sh`,
`lib/initramfs.sh`, `tests/programs/Makefile` (top-level dispatcher unchanged).

---

## Non-goals

- Migrating serial-capture, snapshot, syscall-tests to nolibc (POSIX surface too
  broad; nolibc lacks termios, socket, eventfd, signalfd, shm, sem, msg, klog, pwd).
- Adding new programs or test scripts.
- Changing binary paths or initramfs injection steps.

---

## Design decisions

### Shared Makefile: include vs flat consolidation

Chose `common.mk` included by each thin program Makefile. Flat consolidation
(one Makefile for all programs) would prevent per-program Clang suppressions and
make the file harder to copy into other projects. The include pattern keeps each
program's directory self-contained and explicit.

### common.mk modes

Three modes via pre-include variables:
- **Default** — cross-compiled: 4 arches + Clang x86_64 quality gate (GCC shipped)
- **HOST_ONLY=1** — host-only (serial-capture): GCC=quality-gate, Clang=shipped, x86_64 only
- **FLAGS_ONLY=1** — variables only, no rules (ns/Makefile defines its own multi-binary rules)

### Per-program customization hooks

- `CFLAGS_GCC_EXTRA` — extra GCC flags for all arches
- `CFLAGS_CLANG_EXTRA` — extra Clang flags (e.g. `-Wno-padded` for snapshot)
- `CFLAGS_{x86_64,i386,arm64,riscv}_EXTRA` — arch-specific extras
  (e.g. `-Wno-pointer-to-int-cast` for arm64/riscv cross-compiler spurious warnings)
- `LOG_TAG` — log prefix (default: `$(BIN)`)
- `CC_x86_64 := gcc` — override to drop musl dependency (arena-test nolibc)

### GCC warning set

Arena-test's extended set adopted as the shared baseline for all programs and ns/:
`-Wformat=2 -Wno-unused-parameter -Wshadow -Wwrite-strings -Wstrict-prototypes`
`-Wold-style-definition -Wredundant-decls -Wnested-externs -Wmissing-include-dirs`
`-Wjump-misses-init -Wlogical-op`
Programs that previously used only `-Wall -Wextra -Wpedantic -Werror` will be
checked for new warnings; suppressions added to `CFLAGS_GCC_EXTRA` if needed.

### nolibc evaluation (arena-test and perf-event)

**arena-test**: Compiles cleanly with `gcc -nostdlib -isystem $NOLIBC_DIR -include
nolibc.h` using the full extended warning set + `-Wpedantic -Werror`. Zero new
suppressions. Adopting for x86_64 GCC build. Clang gate keeps musl-clang
(musl-clang injects `-static-libgcc` which triggers `-Wunused-command-line-argument`
under `-nostdlib`, requiring a new suppression → rejected).

**perf-event**: `SYS_perf_event_open` undefined in nolibc's `sys/syscall.h`. The
syscall number is defined in `asm/unistd.h` via musl's `sys/syscall.h` but not
mapped by nolibc's minimal wrapper. Keeping musl.

**Cross-arch (arm64, riscv)**: Not evaluated for nolibc; cross-compilers already
statically link glibc and work reliably. nolibc cross-arch build is possible but
out of scope for this feature.

### ns/ integration

FLAGS_ONLY=1 lets ns/Makefile import CFLAGS_COMMON / CFLAGS_GCC / CC_* variables
from common.mk while keeping its own multi-binary build rules (8 sources × 4 arches
× 1 Clang gate = 40 targets). Full include would require duplicating common.mk's
build_rule template for the multi-binary case — more complexity than it removes.

---

## Testing strategy

- **Structural (CI)** — `test-programs-build.sh`: check each program Makefile
  includes common.mk; check CFLAGS_COMMON in common.mk has `-std=c17`; check ns/
  Makefile includes common.mk with FLAGS_ONLY.
- **Compile (CI, optional)** — `test-programs-build.sh`: `make -C tests/programs`
  when musl-gcc + musl-clang + cross-compilers all present; skip otherwise.
- **Existing per-program CI tests** — `test-arena-test.sh`, `test-perf-event.sh`,
  `test-serial-capture.sh`, `test-snapshot.sh`, `test-syscall-tests.sh`, and
  `test-ns-build.sh` continue to cover build + behavioral verification.
- **No VM/QEMU tests added** — binary paths unchanged; no initramfs changes needed.

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, >70% of 43 decision paths

make ci-test
# Expected: all tests pass including test-programs-build, test-ns-build

# Structural check (no compilers needed)
bash tests/ci/test-programs-build.sh

# Build all programs (requires musl-gcc, musl-clang, cross-compilers)
make -C tests/programs
make -C tests/ns

# Verify arena-test nolibc x86_64 (plain gcc, no musl)
KERNEL_TREE=~/git/linux make -C tests/programs/arena-test ARCHES=x86_64

# ns/ quality upgrade
make -C tests/ns ARCHES=x86_64
```
