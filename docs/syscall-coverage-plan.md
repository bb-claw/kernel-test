# Syscall Coverage — Plan

Branch: `feat/syscall-coverage`
Start date: 2026-08-18

---

## Situation

The ROADMAP.md "Future Tests" table listed seccomp, io_uring, and timerfd/signalfd as pending work —
all three were already implemented (430_–450_). This branch implements the three genuine remaining
candidates: eBPF via bpf() syscall, System V IPC (shm/sem/msg), and moving i386 from the random
dev-test pool into the fixed core.

---

## Problems to Solve

1. **eBPF not tested** — No test exercises `bpf(BPF_PROG_LOAD)`. BPF underpins seccomp-bpf,
   landlock, tc, and XDP; verifier regressions silently break these subsystems. `CONFIG_BPF_SYSCALL`
   is absent from x86_64 defconfig by default and from our `configs/defconfig.config` fragment.

2. **System V IPC not tested** — `CONFIG_SYSVIPC` is on by default in defconfig/kunitconfig but no
   test exercises `shmget`/`shmat`, `semget`/`semop`, or `msgget`/`msgsnd`/`msgrcv`. These are
   used by X11, PostgreSQL, glibc POSIX semaphores, and containers.

3. **i386 only reaches dev-test randomly** — i386 KVM boot is in the random pool (D3, weight 3)
   with no guarantee it runs on any given `make dev-test`. i386 is fast (~20 s, same as x86_64
   KVM) and carries unique 32-bit risks (off_t truncation, VA layout, toybox-i686 quirks).

---

## Goals

1. `490_bpf.sh` passes on defconfig/x86_64: verifier accepts BPF_PROG_TYPE_SOCKET_FILTER program;
   skips gracefully on CONFIG_BPF_SYSCALL=n configs (tinyconfig, allnoconfig).
2. `500_sysvipc.sh` passes on defconfig/x86_64: shm/sem/msg round-trips succeed; skips on
   CONFIG_SYSVIPC=n configs.
3. tinyconfig/i386 and defconfig/i386 run in the fixed core of every `make dev-test`.
4. CI tests (`test-syscall-tests.sh`) verify build and host-side invocation of all new subcommands.
5. BUDGET default raised from 300 s to 360 s to accommodate the two new fixed i386 boots.

---

## Scope

Files/components changed:
- `tests/programs/syscall-tests/syscall-tests.c` — add `bpf`, `sysvipc-shm`, `sysvipc-sem`,
  `sysvipc-msg` subcommands; update usage string
- `tests/custom/490_bpf.sh` — eBPF SOCKET_FILTER test
- `tests/custom/500_sysvipc.sh` — SYSVIPC shm/sem/msg test
- `configs/defconfig.config` — add `CONFIG_BPF_SYSCALL=y`
- `scripts/dev-test.sh` — add C7 (tinyconfig/i386) and C8 (defconfig/i386) to fixed core;
  BUDGET default 300→360; total_paths 35→36; remove D3 from random pool
- `tests/ci/test-syscall-tests.sh` — add `run_subcommand` calls for 4 new subcommands
- `tests/ci/coverage-map.md` — update D3 to fixed core, add D7, update total to 36
- `CLAUDE.md` — ≤5 min → ≤6 min for dev-test
- `memory/workflows.md`, `memory/test-inventory.md`, `memory/project.md`,
  `memory/config-profiles.md`, `memory/code-quality.md` — corresponding updates

No changes to: `lib/initramfs.sh` (syscall-tests binary injection already handles new subcommands),
`configs/kunitconfig.config` (SYSVIPC on by default; BPF_SYSCALL inherited from defconfig base),
`configs/randconfig.config` / `rand500config*.config` (BPF_SYSCALL excluded by default; random
coverage handles it opportunistically).

---

## Non-goals

- Adding eBPF map operations (BPF_MAP_CREATE, BPF_MAP_LOOKUP_ELEM) — the verifier+load path is
  the meaningful regression signal; map operations add complexity with no extra coverage value
- Adding `CONFIG_BPF_SYSCALL=y` to kunitconfig or randdefconfig — defconfig base already covers
  kunitconfig; rand configs benefit from random inclusion
- Testing BPF programs that require CAP_BPF or CAP_NET_ADMIN beyond SOCKET_FILTER
- eBPF CO-RE / BTF — requires libbpf and kernel BTF; out of scope for the Toybox initramfs

---

## Design Decisions

### BPF: inline stable-ABI struct definitions, no linux/bpf.h dependency

`union bpf_attr` is large and arch-sensitive. Using `__has_include(<linux/bpf.h>)` introduces
cross-compiler variation (arm64/riscv cross-compilers may not have the header). Instead, we define
a minimal 40-byte struct (`st_bpf_prog_attr`) covering only the fields needed for BPF_PROG_LOAD.
The kernel accepts sizes ≤ sizeof(union bpf_attr) and zeroes remaining fields, so the 40-byte
struct is safe against all kernel versions ≥ 3.18.

Program: `MOV r0, 0; EXIT` (8 bytes, 2 instructions). Simplest program that passes the verifier
for SOCKET_FILTER — the verifier checks register liveness, return value type, and program
termination. EPERM skipped (would require unprivileged BPF restrictions to be in effect; we run
as root so should not occur).

### SYSVIPC: standard POSIX headers, no inline definitions

musl provides `<sys/ipc.h>`, `<sys/shm.h>`, `<sys/sem.h>`, `<sys/msg.h>` — verified with
`musl-gcc`. Cross-compilers for arm64/riscv also provide these (standard POSIX). No fallback
definitions needed.

Each subcommand creates an IPC object with `IPC_PRIVATE`, exercises the core operation
(write+read for shm, V+P semaphore for sem, send+recv for msg), then removes it with `IPC_RMID`.
Skip on ENOSYS (CONFIG_SYSVIPC=n). Skip guard in 500_sysvipc.sh: `/proc/sysvipc/shm` exists
only when CONFIG_SYSVIPC=y.

### i386 fixed core: NO_BUILD=1, same assumption as existing x86_64 smokes

dev-test already uses NO_BUILD=1 for all VM smokes (C4–C6), assuming kernels are pre-built from
a prior `make all NO_FETCH=1`. The i386 entries (C7, C8) follow the same assumption. On machines
where only x86_64 kernels exist, C7/C8 will fail — same as if C4/C5 had no x86_64 kernel. The
fix is `make all NO_FETCH=1 ARCHS=i386`.

---

## Testing Strategy

- **BPF test** — Fixture-based: `run_subcommand bpf` in test-syscall-tests.sh on host (host kernel
  has CONFIG_BPF_SYSCALL=y). VM smoke: defconfig/x86_64 which now has CONFIG_BPF_SYSCALL=y via
  defconfig.config fragment.
- **SYSVIPC test** — Same pattern: host CI + defconfig/x86_64 VM smoke. Skip on tinyconfig/allnoconfig
  (no CONFIG_SYSVIPC).
- **i386 fixed core** — Covered by dev-test runs themselves (C7 and C8 always execute).
- **No CI test for CONFIG_BPF_SYSCALL in kconfig** — `make lint` (inventory + shellcheck) catches
  structural issues; the VM smoke is the functional gate.

---

## Testing Commands

```sh
# Always run before pushing any branch
make dev-test
# Expected: exit 0, ≥50% decision paths covered within time budget (6 min)

# 1. Lint passes
make lint
# Expected: exit 0

# 2. CI harness self-tests (includes new syscall-tests subcommands)
make ci-test
# Expected: exit 0, all tests pass including bpf/sysvipc-* invocations

# 3. Verify CONFIG_BPF_SYSCALL in defconfig fragment
grep CONFIG_BPF_SYSCALL configs/defconfig.config
# Expected: CONFIG_BPF_SYSCALL=y

# 4. Rebuild programs (ensures new subcommands compile)
make programs
# Expected: exit 0, all 4 arches clean

# 5. Spot-check BPF and SYSVIPC in VM
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=defconfig ARCHS=x86_64
# Expected: 490_bpf PASS, 500_sysvipc PASS in test output
```
