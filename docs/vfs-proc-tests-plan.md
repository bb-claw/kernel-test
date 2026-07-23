# VFS and /proc Tests — Design Plan

## Problem

The current 27 tests cover the bottom of the kernel stack (shell, tmpfs, signals,
pipes, scheduler, network loopback) but leave three actively developed subsystems
completely untested:

- **VFS path resolution** — symlinks, hard links, named pipes (FIFOs)
- **Memory management sysctls** — the entire `/proc/sys/vm/*` namespace
- **Process information** — `/proc/self/fd`, `fdinfo`, `limits`, `io`

None of these require config options beyond what the bootability fragment already
forces on, or have clean skip guards when they are disabled. A regression in any
of them would pass the current test suite undetected.

## Tests

### `260_vfs-links.sh` — VFS path resolution

Tests dentry/inode primitives: symlink creation and resolution, hard link aliasing,
and FIFO queuing. These exercise the VFS lookup path, `link_path_walk()`, and the
FIFO pipe buffer — code that changes with each VFS locking or dentry refcount patch.

**Assertions:**

| # | What | Expected |
|---|---|---|
| 1 | `ln -s target link` | command exits 0 |
| 2 | `readlink link` | returns exact target string |
| 3 | Dangling symlink `-e` | reports false (target absent) |
| 4 | Hard link write visible through alias | `cat hardlink` returns updated content |
| 5 | FIFO write + read round-trip | reader receives exact byte sequence |

**Skip guards:**

- No top-level skip — tmpfs is always mounted; symlinks and hard links work on all
  bootable configs.
- FIFO subtest: skipped on `aarch64` via `uname -m` check. Background writer
  (`echo ... > fifo &`) forks the shell process; on arm64 QEMU TCG the COW fault
  on the parent's full RSS immediately OOMs the guest. Symlink and hard link
  assertions still run on arm64.

**Coverage:** Fires on all 21 bootable config×arch combinations (tmpfs is forced
on by the bootability fragment). FIFO fires on 14/21 (skipped on 3 arm64
combinations).

---

### `270_proc-sys-vm.sh` — `/proc/sys/vm` sysctl namespace

Tests that the VM sysctl handlers are registered, readable, and return values
within kernel-enforced ranges. `mm/` receives patches in every -rc; a broken
`proc_dointvec_minmax` registration or a handler returning garbage would be caught
here. `/proc/buddyinfo` and `/proc/zoneinfo` sanity-check the page allocator zone
accounting.

**Skip guard:** `[ -r /proc/sys/vm/overcommit_memory ] || { skip "procfs absent"; exit 0; }`

**Assertions:**

| # | File | Check |
|---|---|---|
| 1 | `vm/overcommit_memory` | value ∈ {0, 1, 2} |
| 2 | `vm/swappiness` | value 0–200 |
| 3 | `vm/dirty_ratio` | value 1–100 |
| 4 | `vm/dirty_background_ratio` | value 1–100 |
| 5 | `/proc/buddyinfo` | at least one line matching `^Node` |
| 6 | `/proc/zoneinfo` | `^Node 0` present |

Range validation is used (not just presence) to catch handlers returning garbage —
a value of `9999` for `swappiness` would pass a presence-only check but fail here.
Write/restore is not used: more complex, and the VM is torn down after tests anyway.

**Coverage:** Fires on defconfig, kunitconfig, randdefconfig always (3 configs ×
3 arches = 9 combinations). Fires on rand500config when `CONFIG_PROC_FS` is sampled
(~35% of runs based on archive data). Skips on tinyconfig and allnoconfig (procfs
disabled by default).

---

### `280_proc-self-extended.sh` — `/proc/self` process information

Tests the process information interface beyond `/proc/self/maps` (already covered
by `150_mmap.sh`). `fd/` and `fdinfo/` are maintained by VFS, `limits` by the
resource limit subsystem, `io` by task I/O accounting — three separate kernel
subsystems in one test.

**Skip guard:** `[ -d /proc/self/fd ] || { skip "procfs absent"; exit 0; }`

**Assertions:**

| # | Path | Check |
|---|---|---|
| 1 | `/proc/self/fd/0` | exists (stdin always open) |
| 2 | `/proc/self/fd/1` | exists (stdout always open) |
| 3 | `/proc/self/fd/2` | exists (stderr always open) |
| 4 | `/proc/self/fdinfo/1` | contains `pos:` field |
| 5 | `/proc/self/fdinfo/1` | contains `flags:` field |
| 6 | `/proc/self/limits` | contains `Max open files` line |
| 7 | `/proc/self/io` | contains `read_bytes:` field |

For assertion 7, `CONFIG_TASK_IO_ACCOUNTING` may be off in randdefconfig (randomly
disabled). A secondary skip guard `[ -r /proc/self/io ] || skip "task IO accounting off"`
is used for that single assertion rather than bailing the whole test.

**Coverage:** Same as `270_proc-sys-vm.sh` — ~9 combinations always, ~3 additional
in rand500config.

---

## Coverage summary

| Test | tinyconfig | defconfig / kunitconfig / randdefconfig | rand500config | arm64 |
|---|---|---|---|---|
| `260_vfs-links.sh` | **Full** | Full | Full | Partial (no FIFO) |
| `270_proc-sys-vm.sh` | Skip | **Full** | ~35% | Full |
| `280_proc-self-extended.sh` | Skip | **Full** | ~35% | Full |

---

## Non-goals

- **Namespace tests** — require `CONFIG_NAMESPACES` which is off in tinyconfig and
  only ~7% of rand500config runs. Deferred; coverage gain is low for the effort.
- **seccomp** — requires `CONFIG_SECCOMP`; same coverage argument as namespaces.
- **Write/restore sysctl testing** — restoring a sysctl after a write failure risks
  leaving the VM in a bad state; the VM is ephemeral so there is no benefit.
- **Config fragments** — no new fragment needed; skip guards are sufficient and keep
  the config profile count stable.
