# Test 200–240 Subsystem Tests — Plan

Branch: `feat/200-subsystem-tests`
Start date: 2026-07-12

---

## Situation

Tests 001–190 cover boot, procfs, sysfs, network loopback, IPC basics,
memory, signals, pipes, timers, and scheduler. Five kernel subsystems remain
untested: inotify, futex, /proc/net stats, bind mounts, and cgroups v2.
All five are exercisable from a POSIX shell without additional binaries.

---

## New Tests

| Script | Subsystem | Key checks |
|---|---|---|
| `200_inotify.sh` | CONFIG_INOTIFY_USER | `/proc/sys/fs/inotify/max_{queued_events,user_instances,user_watches}` |
| `210_futex.sh` | CONFIG_FUTEX | `/proc/sys/kernel/futex_private_hash_size` (kernel 6.x+) |
| `220_proc-net.sh` | CONFIG_NET + PROC_FS | `/proc/net/dev`, `/proc/net/sockstat`, `/proc/net/protocols` |
| `230_bind-mount.sh` | VFS / MS_BIND | `mount --bind`; file visible at alias path; umount cleanup |
| `240_cgroups.sh` | CONFIG_CGROUPS v2 | `/sys/fs/cgroup/cgroup.controllers`, `cgroup.procs` |

---

## Design Decisions

### All five use skip-on-absent guards

These subsystems are disabled in `tinyconfig`. Tests emit `skip:` when the
required `/proc` or `/sys` interface is absent. Only `kunitconfig`,
`defconfig`, and `randdefconfig` exercise them fully.

### inotify: sysctl-only (no inotifywait)

`inotifywait` is not compiled into the Toybox binary. The three
`/proc/sys/fs/inotify` limit knobs confirm `CONFIG_INOTIFY_USER=y` and
that the subsystem initialized with sane defaults. Actual
`inotify_init`/`inotify_add_watch` testing would require a C helper.

### futex: sysctl check, no fork/wait repeat

`futex_private_hash_size` was added in kernel 6.x and is a reliable
`CONFIG_FUTEX` indicator. Direct `futex(2)` testing requires a helper
binary. The fork/wait relay already covered in `130_fork-exec` is not
repeated here to avoid redundancy.

### /proc/net: three files, if_inet6 skip-on-absent

`/proc/net/dev` is present whenever `CONFIG_NET=y`. `/proc/net/sockstat`
requires `CONFIG_INET`. `/proc/net/protocols` lists all registered protocol
modules. `/proc/net/if_inet6` is skipped-on-absent — no IPv6 interface
is configured in the VM so the file may not exist even when IPv6 is on.

### bind mount: rootfs as source/dest

`/tmp` may not exist in tinyconfig (no `CONFIG_TMPFS` → no tmpfs mount by
init). Source and dest dirs are created directly on the initramfs rootfs
(`/bind-src-<pid>`, `/bind-dst-<pid>`), which is always an in-RAM
filesystem and always writable. The test skips if `mount --bind` fails
(e.g. permission denied or kernel VFS restriction).

### cgroups v2: unified hierarchy only, no child cgroup

`cgroup.controllers` is v2-specific. If only v1 is mounted, or cgroups are
off, the test exits via skip. No child cgroup is created to avoid cleanup
complexity; `cgroup.procs` at the root is sufficient to confirm the
hierarchy is active.

### No elif in any script

Toybox sh 0.8.9 `elif` bug: when the `if`-condition is true, both the
`if`-body and the `else`-body execute. All branching uses nested
`if/else/fi` instead.

---

## Testing

```sh
# kunitconfig exercises most checks; tinyconfig mostly skips
make all NO_FETCH=1 NO_BUILD=1 CONFIGS="kunitconfig tinyconfig" ARCHS="x86_64 arm64 i386"
```
