# tests/ns/

Static C binaries for Linux namespace regression tests.  Built for all four
architectures and injected into the initramfs at `usr/bin/ns-*`.

## Why C binaries?

The namespace regression paths (clone flags, setns, pivot_root, idmaps, …)
require syscalls that Toybox sh cannot make directly.  C binaries cross-compiled
with `-static` run in the minimal Toybox initramfs without any dynamic libraries.

## Binaries

| Binary | Namespace type | Key tests |
|---|---|---|
| `ns-uts` | UTS | `clone` — unshare CLONE_NEWUTS, verify inode change + hostname isolation; `setns <path>` — open ns fd, setns, verify inode matches |
| `ns-ipc` | IPC | `clone` — unshare CLONE_NEWIPC, verify inode change + new IPC namespace |
| `ns-pid` | PID | `clone` — fork into new PID ns, verify child sees PID 1; init-death cascade (SIGKILL to whole ns) |
| `ns-mount` | Mount | `clone` — MS_MOVE, mknod with SB_I_NODEV, propagate_mnt, pivot_root |
| `ns-net` | Network | `clone` — lo-only isolation; proc-net in new ns |
| `ns-user` | User | `clone` — uid 0 inside ns; idmap write; `nested-6` — 6-level nesting (CVE-2018-18955) |
| `ns-cgroup` | Cgroup | `clone` — cgroup ns scoping; release-agent path (CVE-2022-0492) |
| `ns-time` | Time | `clone` — timens_offsets +100s CLOCK_MONOTONIC; `setns-mt` — multi-threaded setns (CVE-2023-23586) |

## Building

```sh
make bootstrap          # builds all 4 arches automatically
# or directly:
make -C tests/ns/ all
```

Outputs land in `bin/<arch>/ns-*` (gitignored).

## Cross-compilation

| Arch | Compiler |
|---|---|
| x86_64 | `gcc` |
| i386 | `gcc -m32` |
| arm64 | `aarch64-linux-gnu-gcc` |
| riscv | `riscv64-linux-gnu-gcc` |

All binaries are built with `-static -O2`.

## VM test scripts

The ns-* binaries are exercised by `tests/custom/290_ns-uts-ipc.sh` through
`360_ns-setns.sh`.  Those scripts require a namespace-enabled kernel config
(`configs/namespaces.config`) and skip gracefully when the binary is absent.

Run with: `make ns-smoke` (kunitnsconfig + tinynsconfig) or `make ns-full`.
