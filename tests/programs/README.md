# tests/programs/

C helper programs compiled for all four architectures and injected into the
initramfs at `usr/bin/`.  Each program exercises a kernel path that POSIX sh
cannot reach directly.

## Programs

| Directory | Binary | Injected as | Used by |
|---|---|---|---|
| `arena-test/` | `arena-test` | `usr/bin/arena-test` | `410_arena-memory.sh` |
| `perf-event/` | `perf-event` | `usr/bin/perf-event` | `400_perf-events.sh` |

## Build

```sh
make bootstrap          # builds all programs for all 4 arches
# or per-program:
make -C tests/programs/arena-test/ all
make -C tests/programs/perf-event/ all
```

Compiled binaries land in `<program>/bin/<arch>/` (gitignored via `.gitignore`
in each subdir).

## Cross-compilation (common pattern)

| Arch | Compiler | Flags |
|---|---|---|
| x86_64 | `gcc` | `-static -O2 -Wall` |
| i386 | `gcc` | `-m32 -static -O2 -Wall` |
| arm64 | `aarch64-linux-gnu-gcc` | `-static -O2 -Wall` |
| riscv | `riscv64-linux-gnu-gcc` | `-static -O2 -Wall` |

All programs use `-std=gnu11`.

## Adding a program

1. Create `tests/programs/<name>/` with `<name>.c`, `Makefile`, and `.gitignore`
   (`bin/`)
2. Follow the cross-compile Makefile pattern from `arena-test/Makefile`
3. Add a build step to `lib/bootstrap.sh` (after the existing program blocks)
4. Add a copy step to `lib/initramfs.sh` (after the existing copy blocks)
5. Write a VM test script `tests/custom/NNN_<name>.sh` with a skip guard for
   the absent binary case
6. Add a CI skip-guard test in `tests/ci/test-arch-scripts.sh`
