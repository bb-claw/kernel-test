# Namespace Regression Test Plan

Branch: `feat/ns-regression-tests`
Start date: 2026-08-05

---

## Situation

The harness currently has no coverage of Linux namespace syscalls.  All eight namespace types
(`CLONE_NEWUTS`, `CLONE_NEWIPC`, `CLONE_NEWPID`, `CLONE_NEWNS`, `CLONE_NEWNET`,
`CLONE_NEWUSER`, `CLONE_NEWCGROUP`, `CLONE_NEWTIME`) are actively developed, and regression
analysis shows repeated reintroduction of the same classes of isolation failures across release
cycles.

The existing `240_cgroups.sh` confirms cgroup v2 presence but does not exercise the cgroup
namespace or any other namespace type.  There is no coverage of `unshare(2)`, `setns(2)`,
mount propagation, PID remapping, or UID mapping — the exact primitives that container runtimes
(runc, containerd, Podman, systemd-nspawn) depend on.

---

## Regression evidence

The following table summarises bugs that were reintroduced at least once, drawn from a survey
of CVE databases, oss-security archives, LKML, and container runtime issue trackers.  These
are the structural weak spots worth encoding as permanent tests.

| Namespace | CVE(s) | Reintroductions | What broke |
|---|---|---|---|
| User + mount (overlayfs) | CVE-2015-1328, CVE-2021-3493, CVE-2023-2640 | 3 | `security.capability` xattr write through overlayfs bypassed `init_user_ns` CAP check |
| Mount + user | none | 2–3 | `MS_MOVE` across user ns boundary broken (5.1–5.3); `SB_I_NODEV` implicit on userns mounts (4.18); `propagate_mnt()` NULL deref in shared→slave propagation tree (pre-6.2) |
| Mount (runc runtime) | CVE-2019-5736, CVE-2021-30465, CVE-2024-21626 | 3 | fd-leak through `/proc/self/fd/` escaping mount ns isolation; CVE-2024-21626 introduced by security fix for CVE-2021-30465 |
| Cgroup + user | CVE-2022-0492 | 1 (3-yr delay) | `cgroup_release_agent_write()` did not check `CAP_SYS_ADMIN` in `init_user_ns`; write was possible from unprivileged user ns |
| PID | CVE-2025-40178 | 1+ | `task_active_pid_ns()` NULL deref in `pid_nr_ns()` during teardown edge cases; recurring pattern in PID ns init-death paths |
| User (idmap) | CVE-2018-18955 | 1 | Nested user ns with >5 UID/GID mapping ranges used binary search that incorrectly reversed kernel→ns direction |
| Time | CVE-2023-23586 | 1 | `timens_install()` `current_is_single_threaded()` check bypassed by io_uring worker threads sharing the process `mm`; use-after-free on VVAR page |
| User (policy) | Ubuntu 23.10+ | intentional | `kernel.apparmor_restrict_unprivileged_userns` (`userns_create` LSM hook, kernel 6.1) blocks `CLONE_NEWUSER` for unprivileged processes by default; tests must detect and skip |

**UTS and IPC namespaces** have the cleanest track record — no repeated regressions found in
post-3.x kernels.  They are still tested because they exercise the core namespace creation and
nsfs inode paths shared by all types.

---

## Goals

1. Cover all eight Linux namespace types with Toybox sh tests inside the QEMU VM
2. Cover the `setns(2)` code path via `nsenter` — the path used by all container runtimes
3. Cover `pivot_root(2)` — the container startup sequence that replaces the root filesystem
4. Provide static C test binaries (`ns-*`) for syscalls unreachable from shell alone:
   `clone(2)` with `CLONE_NEW*`, direct `setns(2)`, `semget/semop`, `CLONE_NEWTIME` clock offsets
5. Introduce six deterministic + randomised ns-variant kernel config profiles so that namespace
   tests run automatically when namespace support is enabled
6. Cross-compile all C binaries unconditionally in `make bootstrap` for all four arches
7. Include Tier 2 CI test coverage for every new shell test script

---

## Config profiles

Seven new config profiles are added, each derived by applying `configs/namespaces.config` on
top of the corresponding base config.

| Profile | Base | Key additions | Build time estimate |
|---|---|---|---|
| `tinynsconfig` | `tinyconfig` | `CONFIG_NAMESPACES` + all 8 types incl. `CONFIG_USER_NS` | ~4 min |
| `defnsconfig` | `defconfig` | `CONFIG_USER_NS=y`, `CONFIG_TIME_NS=y` (already has others) | ~12 min |
| `kunitnsconfig` | `kunitconfig` | namespaces + KUnit framework; used by `make ns-smoke` | ~12 min |
| `rand500nsconfig` | `rand500config` | namespaces fragment wins; random 500 options on top | ~5 min |
| `randdefnsconfig` | `randdefconfig` | namespaces fragment wins; random disable on top | ~12 min |
| `kunitrandnsconfig` | `kunitrandconfig` | namespaces + KUnit module sweep | ~15 min |
| `randnsconfig` | `randconfig` | namespaces fragment wins; unconstrained random | ~25 min |

`configs/namespaces.config` fragment:

```
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_USER_NS=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_NS=y
CONFIG_TIME_NS=y
CONFIG_TMPFS=y
CONFIG_PROC_FS=y
CONFIG_NET=y
```

**Base derivation** — `lib/build.sh` uses a `case` statement to derive `NS_BASE` from the
profile name, then applies `configs/namespaces.config` on top:

```bash
case "$CONFIG" in
    tinynsconfig)      NS_BASE=tinyconfig ;;
    defnsconfig)       NS_BASE=defconfig ;;
    kunitnsconfig)     NS_BASE=kunitconfig ;;
    rand500nsconfig)   NS_BASE=rand500config ;;
    randdefnsconfig)   NS_BASE=randdefconfig ;;
    kunitrandnsconfig) NS_BASE=kunitrandconfig ;;
    randnsconfig)      NS_BASE=randconfig ;;
esac
```

Build step for each `*nsconfig`: run the base config target, append
`configs/namespaces.config`, run `olddefconfig`, then proceed identically to any other
bootable config.

`randnsconfig` is build-only (like plain `randconfig`); it is listed in `BUILD_ONLY_CONFIGS`.
All other ns-variant profiles are bootable.

**Convenience targets** — mirrors of `make smoke` and `make full` for ns-variant configs:

```sh
make ns-smoke   # kunitnsconfig + tinynsconfig (fast sanity — requires make bootstrap)
make ns-full    # kunitnsconfig tinynsconfig defnsconfig randdefnsconfig rand500nsconfig
make extended   # make full then make ns-full (10 configs total); intended for staging automation
```

---

## C test binaries

### Location and cross-compilation

Sources live in `tests/ns/`.  One C file per namespace type, plus one for mount operations.

```
tests/ns/
  Makefile              # cross-compiles all 8 binaries × 4 arches
  ns-uts.c
  ns-ipc.c
  ns-pid.c
  ns-mount.c
  ns-net.c
  ns-user.c
  ns-cgroup.c
  ns-time.c
  bin/
    x86_64/             # ns-uts, ns-ipc, ns-pid, ns-mount, ns-net, ns-user, ns-cgroup, ns-time
    i386/
    arm64/
    riscv/
```

All binaries are statically linked (`-static`).  `make bootstrap` adds:

```bash
make -C "$REPO/tests/ns" all
```

The `tests/ns/Makefile` uses `aarch64-linux-gnu-gcc`, `riscv64-linux-gnu-gcc`, and
`x86_64-linux-gnu-gcc -m32` for cross targets.

### Initramfs integration

`lib/initramfs.sh` copies `tests/ns/bin/<arch>/ns-*` into the initramfs at `/usr/bin/`.
If the binary is absent (bootstrap not run), initramfs.sh prints a warning but continues;
the test scripts handle missing binaries with a skip.

### Binary API

Each binary accepts a subcommand:

| Binary | Subcommands |
|---|---|
| `ns-uts` | `clone` (unshare UTS, verify inode change), `setns <ns-path>` (join by fd, verify inode match) |
| `ns-ipc` | `clone` (unshare IPC, verify inode change), `semop` (create SysV semaphore, verify isolation) |
| `ns-pid` | `clone` (fork into PID ns, verify PID=1 inside), `nspid` (verify NSpid field in /proc/status), `init-death` (kill ns init, verify no zombie escapes) |
| `ns-mount` | `move` (bind + MS_MOVE across userns boundary), `mknod` (mknod in userns mount, must succeed), `propagate` (shared→slave→private propagation tree, no NULL deref), `pivot` (pivot_root in tmpfs) |
| `ns-net` | `clone` (verify only `lo` visible in new net ns), `proc-net` (verify `/proc/net/dev` is ns-scoped) |
| `ns-user` | `idmap` (write uid_map, verify cat /proc/self/uid_map), `nested-6` (nested ns with 6 UID ranges, verify EACCES on host file) |
| `ns-cgroup` | `release-agent` (write to release_agent from userns, must EPERM), `scoping` (verify /sys/fs/cgroup shows ns root, not host root) |
| `ns-time` | `offset` (CLOCK_MONOTONIC offset in new time ns), `setns-mt` (setns from multi-threaded process must EINVAL or EUSERS) |

---

## Shell test files

Numbers continue from `280_proc-self-extended.sh`.  Each file has a header guard:

```sh
[ -e /proc/self/ns/uts ] || { echo "skip: CONFIG_NAMESPACES=n"; exit 0; }
```

Individual sub-tests guard their specific namespace type before exercising it.

### `290_ns-uts-ipc.sh` — UTS + IPC + nsfs interface

Covers the simplest namespace types and the common nsfs inode interface used by all types.

**UTS tests:**
- Isolation: `unshare -u hostname ns-target` inside returns `ns-target`; parent unaffected
- Inode uniqueness: `readlink /proc/self/ns/uts` before/after `unshare -u` must differ
- Inode stability: two processes in same UTS ns must show identical inode numbers
- `ns-uts clone`: exercises `clone(CLONE_NEWUTS)` directly, verifies inode via C

**IPC tests:**
- Inode uniqueness: `unshare -i` creates distinct inode
- `ns-ipc semop`: create SysV semaphore in new IPC ns; verify it does not appear in parent
  namespace (`ipcs` output via `/proc/sysvipc/sem`)

**nsfs interface (all configured types):**
- `/proc/self/ns/<type>` exists and is a symlink for each of: `uts ipc pid mnt net` (plus
  `user cgroup time` when available)
- `readlink` format matches `<type>:[0-9]+`
- `/proc/sys/user/max_uts_namespaces`, `max_ipc_namespaces`, `max_pid_namespaces`,
  `max_net_namespaces`, `max_user_namespaces` are readable non-zero integers

### `300_ns-pid.sh` — PID namespace

Covers the historically most regression-prone namespace type.  PID namespace teardown and
`/proc` remapping are touched in nearly every major kernel release.

- PID remapping: `unshare -fp --mount-proc` gives PID=1 inside (from `ns-pid clone`)
- `NSpid` field: `/proc/self/status` shows two numbers in `NSpid` line (ns-local + host)
- `/proc` scoping: `ps` inside PID ns lists only ns-local PIDs
- `pid_for_children` vs `pid`: after `unshare -p` without fork, `pid_for_children` inode
  changes but `pid` inode does not; inode must differ (regression: CVE-2025-40178 family)
- Init death: `ns-pid init-death` forks ns, kills PID 1, waits; host namespace must not
  receive stray signals; `/proc` on host must not contain zombie from the ns
- `/proc/sys/user/max_pid_namespaces`: readable non-zero

**Regression: CVE-2025-40178** — `task_active_pid_ns()` NULL deref in `pid_nr_ns()` triggered
by accessing `/proc/<pid>/status` for a process whose PID namespace is being torn down.  The
`init-death` test exercises this teardown path.

### `310_ns-mount.sh` — Mount namespace

Mount namespace propagation is the most actively modified area; the 5.1–5.3 window had 2–3
distinct regressions from the same developers.

- Basic isolation: bind mount inside `unshare -m` does not appear in parent `/proc/mounts`
- Toybox autodetects bind (directory on directory) without `--bind` flag
- `MS_MOVE` across userns boundary (`ns-mount move`): must succeed; regression in 5.1 returned
  EINVAL (no CVE; fixed in 5.2-rc6)
- `mknod` in userns mount (`ns-mount mknod`): create `/dev/null c 1 3` in a tmpfs mounted
  in a user+mount namespace; must succeed; regression in 4.18 set `SB_I_NODEV` implicitly
- Mount propagation tree (`ns-mount propagate`): create shared→slave→private tree, bind mount
  through it; must not crash kernel; regression: `propagate_mnt()` NULL deref in slave
  propagation path (no CVE anchor found; fixed pre-6.2)
- `pivot_root` (`ns-mount pivot`): in a new mount namespace, create minimal rootfs in `/tmp`,
  bind-mount `/proc`, call `pivot_root`; must succeed and `/proc/self/mountinfo` inside must
  reflect new root; exercises exact container startup sequence
- `/proc/self/fd/` leak check: no fd in `/proc/self/fd/` resolves to a host path outside the
  mount namespace; motivation: CVE-2024-21626 (`/sys/fs/cgroup` fd leaked from host ns)

### `320_ns-net.sh` — Network namespace

- Interface isolation: `unshare -n cat /proc/net/dev` must show only header + lo; host
  interfaces must not appear (no `ip` in Toybox; use `/proc/net/dev` directly)
- `/proc/net` scoping: `/proc/net/tcp`, `/proc/net/udp` inside new net ns must be empty or
  contain only ns-local state (historical: some `/proc/net` files leaked from `init_net`)
- lo registration: `unshare -n cat /proc/net/dev | grep ^lo:` must show lo with zero counters
  (confirms per-ns lo registration)
- Inode uniqueness: same pattern as UTS
- `/proc/sys/user/max_net_namespaces`: readable non-zero

### `330_ns-user.sh` — User namespace

Skip guard: `[ -e /proc/self/ns/user ] || { echo "skip: CONFIG_USER_NS=n"; exit 0; }`
Additional guard: `unshare -U true 2>/dev/null || { echo "skip: userns creation blocked"; exit 0; }` (covers AppArmor `userns_create` hook, Ubuntu 6.1+)

- UID mapping: `unshare -Ur id` must show `uid=0 gid=0` (map-root-user mechanic)
- `/proc/self/uid_map` written: `unshare -U cat /proc/self/uid_map` must produce a valid map
  line (`0 <host-uid> 1`); motivation: uid_map write failure breaks all rootless containers
- Capability scoping: inside `unshare -U`, `/proc/self/status | grep CapEff` shows full
  capability mask; outside, it reflects host process caps
- `ns-user idmap`: direct `write()` to `uid_map` via C, verifies the kernel-side parsing
- `ns-user nested-6`: nested user namespace with 6 UID ranges; `open("/etc/shadow", O_RDONLY)`
  must return EACCES; motivation: CVE-2018-18955 (binary search reversal in idmap >5 ranges)
- `cgroup release_agent` from userns: `echo /tmp/x > /sys/fs/cgroup/.../release_agent` from
  inside a user namespace must return EPERM; motivation: CVE-2022-0492 (3-yr-delayed fix)

### `340_ns-cgroup.sh` — Cgroup namespace

Skip guard: `[ -e /proc/self/ns/cgroup ] || { echo "skip: CONFIG_CGROUP_NS=n"; exit 0; }`

- Inode uniqueness: `unshare -C` creates distinct cgroup ns inode
- `/sys/fs/cgroup` scoping: inside `unshare -C`, `/sys/fs/cgroup` must show the process's
  own cgroup as root (`/` not `/user.slice/...`); confirms ns remapping works
- `release_agent` EPERM: `ns-cgroup release-agent` writes to `release_agent` from inside a
  user+cgroup namespace; must return EPERM; motivation: CVE-2022-0492
- `/proc/self/ns/cgroup` stable symlink after multiple unshare/enter cycles

### `350_ns-time.sh` — Time namespace

Skip guard: `[ -e /proc/self/ns/time ] || { echo "skip: CONFIG_TIME_NS=n"; exit 0; }`

- `ns-time offset`: in a new time namespace, set `CLOCK_MONOTONIC` offset +100s via
  `/proc/self/timens_offsets`; read `CLOCK_MONOTONIC`; verify it differs from host by ~100s
- `ns-time setns-mt`: from a process with two threads, attempt `setns` into a time namespace;
  must return `EINVAL` or `EUSERS` (`timens_install()` returns `EUSERS` when
  `current_is_single_threaded()` fails); motivation: CVE-2023-23586 (io_uring bypassed this
  check — our test confirms the check is in place)
- `/proc/self/timens_offsets`: readable, shows `monotonic 0 0` and `boottime 0 0` in init timens
- Inode uniqueness: `unshare -T` creates distinct time ns inode
- `pid_for_children` / `time_for_children` both present as `/proc/self/ns/` symlinks

### `360_ns-setns.sh` — `nsenter` / `setns(2)` code path

This file covers a completely different kernel path from `unshare`.  Container runtimes create
a namespace in one process and join it from another via `setns(2)`.  The `unshare` tests never
exercise this path.

**Setup pattern** used by all tests in this file:

```sh
unshare -u sh -c 'hostname ns-target; touch /tmp/ns-ready; sleep 60' &
target_pid=$!
# Poll until namespace is ready (avoids sleep-based races)
i=0; while [ ! -f /tmp/ns-ready ] && [ $i -lt 20 ]; do i=$((i+1)); done
```

**Tests:**

- UTS re-entry: `nsenter -t $target_pid -u hostname` returns `ns-target`
- Inode match: `readlink /proc/self/ns/uts` after nsenter matches `readlink /proc/$target_pid/ns/uts`
- Multi-ns entry: `nsenter -t $target_pid -u -i` enters both UTS + IPC simultaneously; both
  inodes must match target
- IPC re-entry: inode match for IPC ns
- Mount re-entry: inode match for mount ns
- Net re-entry: `/proc/net/dev` after `nsenter -n` reflects target net ns (different inode)
- Cgroup re-entry: cgroup ns inode match (when available)
- `ns-uts setns <path>`: C-level `setns(fd, CLONE_NEWUTS)` verifies inode match and that
  `gethostname()` returns target's hostname; covers the exact kernel path runc uses
- Error path `-F` with PID ns: `nsenter -t $pid -p -F` (no-fork into PID ns) must exit
  non-zero; Toybox must not crash

---

## Tier 2 CI test coverage

Following the project rule that every new feature requires CI tests, each shell test script
gets a corresponding `tests/ci/test-ns-*.sh` fixture test.

| Test file | What is fixture-tested |
|---|---|
| `tests/ci/test-ns-configs.sh` | `configs/namespaces.config` fragment options; NS_BASE derivation for all 7 profiles; `ns-smoke`/`ns-full` targets in Makefile |
| `tests/ci/test-ns-build.sh` | `tests/ns/Makefile` produces binaries for all 4 arches; binaries are statically linked; `file` output shows static ELF |
| `tests/ci/test-ns-initramfs.sh` | `lib/initramfs.sh` with ns binaries present: `/usr/bin/ns-uts` etc. appear in cpio listing; absent binaries produce warning not error |
| `tests/ci/test-ns-scripts.sh` | Each `tests/custom/290_ns-*.sh` skip-guard logic: simulate `CONFIG_NAMESPACES=n` by removing `/proc/self/ns/uts` equivalent; verify exit 0 with skip message |

The CI tests do not run the namespace syscalls themselves (that requires a real kernel in
QEMU).  They test the scaffolding: config derivation, binary build, initramfs packing,
and skip guard correctness.

---

## Files changed

### kernel-test/ (harness repo)

| File | Change |
|---|---|
| `configs/namespaces.config` | New — fragment enabling all 8 namespace types |
| `tests/ns/Makefile` | New — cross-compiles 8 C binaries × 4 arches |
| `tests/ns/ns-uts.c` | New — clone + setns for UTS namespace |
| `tests/ns/ns-ipc.c` | New — clone + semop for IPC namespace |
| `tests/ns/ns-pid.c` | New — clone + NSpid + init-death for PID namespace |
| `tests/ns/ns-mount.c` | New — MS_MOVE + mknod + propagate + pivot_root |
| `tests/ns/ns-net.c` | New — clone + /proc/net/dev scoping |
| `tests/ns/ns-user.c` | New — uid_map write + nested-6 idmap test |
| `tests/ns/ns-cgroup.c` | New — release_agent EPERM + cgroup scoping |
| `tests/ns/ns-time.c` | New — clock offset + setns-mt EINVAL |
| `tests/custom/290_ns-uts-ipc.sh` | New — UTS + IPC + nsfs interface |
| `tests/custom/300_ns-pid.sh` | New — PID namespace |
| `tests/custom/310_ns-mount.sh` | New — mount namespace |
| `tests/custom/320_ns-net.sh` | New — network namespace |
| `tests/custom/330_ns-user.sh` | New — user namespace |
| `tests/custom/340_ns-cgroup.sh` | New — cgroup namespace |
| `tests/custom/350_ns-time.sh` | New — time namespace |
| `tests/custom/360_ns-setns.sh` | New — nsenter / setns path |
| `lib/initramfs.sh` | Extend: copy `tests/ns/bin/<arch>/ns-*` to `/usr/bin/` in initramfs |
| `lib/bootstrap.sh` | Extend: `make -C tests/ns all` to build all C binaries |
| `Makefile` | Add `ns-smoke` + `ns-full` targets; update `PHONY`, `help` |
| `lib/build.sh` | Add `NS_BASE` case statement for 7 ns-variant profiles; apply `namespaces.config` fragment |
| `tests/ci/test-ns-configs.sh` | New — CI: namespaces.config fragment + ns-base derivation + Makefile targets |
| `tests/ci/test-ns-build.sh` | New — CI: ns binary build produces static ELFs |
| `tests/ci/test-ns-initramfs.sh` | New — CI: initramfs includes ns binaries |
| `tests/ci/test-ns-scripts.sh` | New — CI: skip-guard logic in each ns test script |
| `memory/test-inventory.md` | Add 8 new test script rows |
| `memory/config-profiles.md` | Add 7 ns-variant profiles (incl. kunitnsconfig) |
| `CLAUDE.md` | Add all new files to Key files table |

---

## Verification checklist

1. `make bootstrap` builds `tests/ns/bin/{x86_64,i386,arm64,riscv}/ns-*` (8 × 4 = 32 binaries)
2. `make ns-smoke NO_FETCH=1` completes; all 38 tests pass on all 4 arches × kunitnsconfig + tinynsconfig (8 combos)
3. `make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64` — namespace tests skip gracefully
   (tinyconfig without namespaces fragment has no `CONFIG_NAMESPACES`)
4. `make all NO_FETCH=1 CONFIGS=defnsconfig ARCHS=x86_64` — USER_NS tests run (defnsconfig
   adds `CONFIG_USER_NS=y`)
5. `make ci-test` passes all 16 CI tests including the four `test-ns-*.sh` fixtures
6. `360_ns-setns.sh` passes on defnsconfig x86_64 (cross-setns inode match end-to-end)
7. `310_ns-mount.sh` pivot_root subtest passes (new tmpfs rootfs in /tmp, pivot succeeds)
8. `330_ns-user.sh` nested-6 idmap subtest: `open("/etc/shadow", O_RDONLY)` returns EACCES
9. `350_ns-time.sh` setns-mt subtest: `ns-time setns-mt` returns EINVAL or EUSERS from multi-threaded context

---

## Non-goals

- No overlayfs tests (requires block device or loop mount; not available in initramfs)
- No AppArmor/SELinux MAC policy tests (require loaded policy; not in QEMU test kernel)
- No network stack tests beyond interface isolation (no routing, iptables, or TC in Toybox)
- No cgroup resource limit tests (separate from cgroup namespace; existing `240_cgroups.sh` covers presence)
- No seccomp tests (separate subsystem; planned as follow-up)
- No io_uring integration tests (the CVE-2023-23586 test covers the relevant kernel check via `ns-time setns-mt`)
