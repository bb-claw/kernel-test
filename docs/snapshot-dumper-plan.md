# Snapshot Dumper — Plan

Branch: `feat/snapshot-dumper`
Start date: 2026-08-11
Status: DONE

---

## Situation

The test suite captures serial output (`dmesg.txt`) for every VM run, but extracting
structured machine information (kernel version, memory, taint state) from a long serial
log is fragile. A dedicated C binary that runs at boot, reads /proc and calls uname(2),
and writes a compact structured report gives the harness a stable artifact to validate
and archive alongside test results.

---

## Goals — all completed

1. Add `tests/programs/snapshot/snapshot.c` — C binary, cross-compiled for 4 arches.
2. Add `tests/programs/snapshot/Makefile` — cross-compile for 4 arches, Clang gate.
3. Inject the binary into the initramfs; run it early in `/init` before the test loop.
4. Add `tests/custom/480_snapshot.sh` — validates the output file `/tmp/snapshot.txt`.
5. Add `tests/ci/test-snapshot.sh` — CI build + behavioral test.
6. Wire into `lib/initramfs.sh` and `lib/bootstrap.sh`.

---

## Scope

Files changed:
- `tests/programs/snapshot/snapshot.c`    — C binary, 26 fields
- `tests/programs/snapshot/Makefile`      — cross-compile for 4 arches + clang gate
- `tests/programs/Makefile`               — snapshot added to recursive `make all`
- `tests/custom/480_snapshot.sh`          — in-VM validation of /tmp/snapshot.txt
- `lib/initramfs.sh`                      — run snapshot in /init + inject binary
- `lib/bootstrap.sh`                      — build snapshot after syscall-tests
- `tests/ci/test-snapshot.sh`             — Tier 2 CI: build + behavioral (35 assertions)
- `memory/test-inventory.md`              — row 480_, next slot 490_
- `memory/project.md`                     — current state updated

---

## Output format

One header line, one `LABEL: value` line per field, `snapshot_ok=1` on clean exit:

```
** SNAPSHOT **
       HOSTNAME: (none)
          UNAME: Linux (none) 7.2.0-rc7 ...
           INIT: init
         UPTIME: 0h 0m 3s
        LOADAVG: 0.00 0.00 0.00 2/64 72
         MEMORY: total=476420 free=445460 avail=440000 kB
      KERNELMEM: slab=7388 sunreclaim=6524 kstack=1024 kB
      HUGEPAGES: total=0 size=2048
           SWAP: total=0 used=0 kB
       PAGESIZE: 4096
            CPU: QEMU Virtual CPU version 2.5+  cores=1
          FLAGS: avx avx2 aes
    CLOCKSOURCE: kvm-clock
             FS: count=17 cgroup2=1 btrfs=0 ext4=0
           USER: root uid=0
           ASLR: 0
  DMESG_RESTRICT: 0
  KPTR_RESTRICT: 0
     SCHEDSTATS: 0
    CGROUP_CTRL: cpuset cpu io memory hugetlb pids rdma misc
        ENTROPY: 256
        #MODULES: 0
        TAINTED: 0
          DMESG: oops=0 bugs=0 warns=0 panics=0
        CMDLINE: console=ttyS0,115200 ...
snapshot_ok=1
```

LSM is emitted only when securityfs is mounted and readable.
SCHEDSTATS and CGROUP_CTRL are emitted only when their /proc or /sys paths exist.

---

## Fields collected (26 total)

| Field | Source | Notes |
|---|---|---|
| HOSTNAME | gethostname(2) | Always present |
| UNAME | uname(2) | Always present |
| INIT | /proc/1/comm | Skipped if procfs absent |
| UPTIME | /proc/uptime | Formatted as Xd Xh Xm Xs |
| LOADAVG | /proc/loadavg | Raw line |
| MEMORY | /proc/meminfo | total/free/avail kB |
| KERNELMEM | /proc/meminfo | slab/sunreclaim/kstack kB |
| HUGEPAGES | /proc/meminfo | total hugepages + page size |
| SWAP | /proc/meminfo | total/used kB |
| PAGESIZE | sysconf(_SC_PAGESIZE) | Always present |
| CPU | /proc/cpuinfo | model name + core count (streaming) |
| FLAGS | /proc/cpuinfo | Known ISA flags: avx/avx2/aes/rdrand/smep/smap/fp/asimd/lse/sve/mte |
| CLOCKSOURCE | /sys/.../current_clocksource | Skipped if sysfs absent |
| FS | /proc/filesystems | count + cgroup2/btrfs/ext4 presence (streaming) |
| USER | getuid() + getpwuid() | username + uid |
| LSM | /sys/kernel/security/lsm | Skipped if securityfs absent or CONFIG_SECURITYFS=n |
| ASLR | /proc/sys/kernel/randomize_va_space | Skipped if procfs absent |
| DMESG_RESTRICT | /proc/sys/kernel/dmesg_restrict | Skipped if procfs absent |
| KPTR_RESTRICT | /proc/sys/kernel/kptr_restrict | Skipped if procfs absent |
| SCHEDSTATS | /proc/sys/kernel/sched_schedstats | Silently skipped if absent |
| CGROUP_CTRL | /sys/fs/cgroup/cgroup.controllers | Silently skipped if absent |
| ENTROPY | /proc/sys/kernel/random/entropy_avail | Skipped if procfs absent |
| #MODULES | /proc/modules | Count of loaded modules (streaming) |
| TAINTED | /proc/sys/kernel/tainted | Skipped if procfs absent |
| DMESG | klogctl(KLOG_READ_ALL) | oops/bugs/warns/panics counts |
| CMDLINE | /proc/cmdline | Skipped if procfs absent |

---

## Design Decisions

### try_read_file() for all proc/sysfs reads

All `/proc` and `/sys` reads use `try_read_file()` which silently returns -1 on any
error (ENOENT, EACCES, etc.) without incrementing `fail_count`. This allows the binary
to exit 0 on tinyconfig and allnoconfig where `CONFIG_PROC_FS=n` and `CONFIG_SYSFS=n`.

`fail_count` is reserved for genuine system-level failures: gethostname, uname,
sysconf, malloc OOM, and klogctl (non-EPERM). These indicate real problems.

### Streaming for large files

`/proc/cpuinfo`, `/proc/modules`, and `/proc/filesystems` are streamed in 4 KB
chunks with a line buffer rather than read into a fixed buffer. This handles the
flags line (500+ chars on x86) and /proc/modules (>65 KB on loaded systems).

### LSM is optional

`/sys/kernel/security/lsm` requires `CONFIG_SECURITYFS=y` — absent from the
default x86_64 defconfig. The VM test skips the LSM check when the field is not
in the snapshot file.

### Run at boot, not as a test subcommand

snapshot runs in `/init` before the test loop, writing to `/tmp/snapshot.txt`.
This captures dmesg before any test scripts add output to the ring buffer.
The 480_ test script validates the file; it does not re-run the binary.
If the binary is absent (make bootstrap not run), the test skips cleanly.

### No capability marker

snapshot has no external kernel-config dependency that can be checked at
initramfs-build time. The binary is always injected when built; the test skips on
absent binary. This mirrors the syscall-tests pattern (no marker, runtime skip).

### Clang quality gate (x86_64 only)

Same pattern as arena-test and syscall-tests: `musl-gcc` for all 4 arches (shipped),
`musl-clang` for x86_64 only (quality gate, not shipped). Suppressions:
`-Wno-padded` (struct utsname), `-Wno-disabled-macro-expansion` (musl stderr),
`-Wno-unsafe-buffer-usage` (bounds-correct pointer arithmetic).

---

## Test Script Logic

### 480_snapshot.sh (in-VM)

```
binary /usr/bin/snapshot present?    → no  → skip
/tmp/snapshot.txt exists?            → no  → fail
** SNAPSHOT ** header present?       → no  → fail
syscall-based fields (HOSTNAME/UNAME/PAGESIZE/USER/DMESG) → mandatory
/proc/uptime readable?               → no  → skip proc-based field checks
  proc-based fields (INIT/UPTIME/LOADAVG/MEMORY/...) → mandatory
  LSM present in file?               → no  → skip (CONFIG_SECURITYFS=n ok)
snapshot_ok=1 present?               → no  → fail
```

### test-snapshot.sh (CI / host)

```
source files present?                → assert
musl available?  → make clean all; verify all arch binaries + clang binary
cross-compilers?  → informational notice if absent
binary present?   → no → finish + exit 0 (skip behavioral)
binary exits 0?                      → assert
output: ** SNAPSHOT ** header?       → assert
output: 25 mandatory fields?         → assert (SCHEDSTATS/CGROUP_CTRL present on host)
snapshot_ok=1?                       → assert
```

---

## Testing Commands

```sh
# Build
make -C tests/programs/snapshot

# CI
make ci-test  # includes test-snapshot.sh (35 assertions)

# In-VM: minimal config
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS=x86_64

# In-VM: full defconfig
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=defconfig ARCHS=x86_64

# Smoke (kunitconfig + tinyconfig, all 4 archs)
make smoke NO_FETCH=1
```
