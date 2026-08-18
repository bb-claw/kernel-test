# Test Inventory

## Execution

Scripts in `tests/001_smoke.sh` and `tests/custom/NNN_*.sh` are copied into the initramfs
and run in filename-sorted order by `/init`. Protocol:
```
> TEST RUN: <name>     # before script
< TEST PASS: <name>    # exit 0
< TEST FAIL: <name>    # non-zero exit
```
`vm.sh` counts `< TEST PASS:` / `< TEST FAIL:` markers → `TESTS_PASS` / `TESTS_FAIL`.

---

## Test Scripts

| Script | What it exercises |
|---|---|
| `001_smoke` | Shell arithmetic, `/dev/null`, `/proc/version`, `/sys/kernel` |
| `001_print-dmesg` | Diagnostic dmesg dump — always passes; useful for post-failure inspection |
| `010_check-proc` | `/proc`: cpuinfo, meminfo, uptime, cmdline, filesystems |
| `020_check-sysfs` | `/sys`: kernel, block, class/net hierarchy |
| `030_check-dmesg` | dmesg: kernel version string, no early oops/panic |
| `040_check-devnodes` | `/dev`: null, zero, console, urandom nodes |
| `050_check-kernel` | `/proc/version` format, UTS fields, `/proc/sys/kernel` |
| `060_check-tmpfs` | tmpfs write/read round-trip |
| `070_check-proc-interrupts` | `/proc/interrupts` readable + non-empty |
| `080_check-slabinfo` | `/proc/slabinfo` (CONFIG_SLUB_DEBUG; skip if absent) |
| `090_check-clocksource` | Active clocksource in dmesg |
| `100_network-loopback` | Bring up `lo`, ping 127.0.0.1 (CONFIG_NET + CONFIG_INET) |
| `110_tmpfs-stress` | 1 MiB write/read/verify + 20-file inode allocation on tmpfs |
| `120_rng` | `/dev/urandom` read at 512 B and 4096 B |
| `130_fork-exec` | fork/exec, exit-code propagation, 20 sequential forks, SIGCHLD |
| `140_sysctl` | `/proc/sys` read + write/restore of hostname, pid_max, panic, swappiness |
| `150_mmap` | VMA table via `/proc/self/maps`: count, `[stack]`, anonymous; `/proc/meminfo` AnonPages |
| `160_signal` | `kill -0` self; SIGTERM/SIGKILL/SIGUSR1 via `/bin/kill` + busyloop target; SigBlk/SigIgn/SigCgt fields |
| `170_pipe` | Basic pipe data flow, 3-process pipeline, exit-code, 1 MiB transfer, 10 sequential writes |
| `180_timer` | `/proc/uptime` readable + advancing, epoch sanity via `date +%s`, `sleep 0`, `/proc/timer_list` |
| `190_scheduler` | `/proc/loadavg` format, `nice -n ±N` (setpriority), context switch counters, `/proc/schedstat` |
| `200_inotify` | `/proc/sys/fs/inotify/max_{queued_events,user_instances,user_watches}` (CONFIG_INOTIFY_USER) |
| `210_futex` | `/proc/sys/kernel/futex_private_hash_size` (CONFIG_FUTEX, kernel 6.x+); `/proc/sys/kernel/sem` |
| `220_proc-net` | `/proc/net/dev`, `/proc/net/sockstat`, `/proc/net/protocols`, `/proc/net/if_inet6` |
| `230_bind-mount` | `mount --bind` rootfs dirs; file visible at alias; `/proc/mounts` entry; umount cleanup |
| `240_cgroups` | `/sys/fs/cgroup/cgroup.controllers`, `cgroup.procs`, `cgroup.subtree_control` (v2 only) |
| `250_debug-42` | `/proc/debug_42` returns "42" — confirms CONFIG_DEBUG_42 built in and procfs operational; skips when not built in |
| `260_vfs-links` | Symlink create/readlink/dangling, hard link aliasing, FIFO mkfifo+type check+open/close via exec 3<> (O_RDWR — no fork, no blocking I/O, safe on all arches) |
| `270_proc-sys-vm` | `/proc/sys/vm` range validation: overcommit_memory∈{0,1,2}, swappiness 0–200, dirty_ratio/dirty_background_ratio 1–100; /proc/buddyinfo + /proc/zoneinfo sanity; skips when procfs absent |
| `280_proc-self-extended` | `/proc/self/fd` (stdin/stdout/stderr), `fdinfo/1` (pos/flags), `limits` (Max open files/processes), `io` (read_bytes/write_bytes); skips when procfs absent |
| `290_ns-uts-ipc` | nsfs inode format for all 8 ns types; `/proc/sys/user` limits; UTS hostname isolation via unshare; ns-uts/ns-ipc C binaries |
| `300_ns-pid` | PID namespace inode change via unshare -fp; ns-pid clone (PID=1) + init-death cascade SIGKILL |
| `310_ns-mount` | Mount ns inode + bind visibility; ns-mount: MS_MOVE, mknod SB_I_NODEV, propagate_mnt, pivot_root |
| `320_ns-net` | Net ns inode + host interface leak detection (lo + per-namespace admin tunnels allowed; real host iface = fail); ns-net clone + proc-net |
| `330_ns-user` | User ns inode + uid 0 in ns; ns-user idmap + nested-6 (CVE-2018-18955) |
| `340_ns-cgroup` | Cgroup ns inode + /sys/fs/cgroup; ns-cgroup scoping + release-agent (CVE-2022-0492) |
| `350_ns-time` | Time ns timens_offsets; ns-time offset (+100s CLOCK_MONOTONIC) + setns-mt (CVE-2023-23586) |
| `360_ns-setns` | setns(2) code path via ns-uts setns: self-setns + cross-setns into foreign UTS ns |
| `370_riscv-isa` | RISC-V ISA string from /proc/cpuinfo: base extensions I M A F D C present; 64-bit confirmed; skip on non-riscv |
| `380_arm64-features` | ARM64 mandatory features from /proc/cpuinfo Features line: FP + NEON (asimd); atomics (LSE) and SVE/PAC/MTE optional (QEMU `-cpu cortex-a57` is ARMv8.0-A — LSE absent is expected, not a regression); skip on non-arm64 |
| `390_watchdog` | Watchdog subsystem: /dev/watchdog presence + char-device check; /sys/class/watchdog/* enumeration (all registered devices; name-based correlation to match $WD to its sysfs entry for correct nowayout); magic-close write "V" (skipped when NOWAYOUT=1); softlockup sysctl opportunistic; /proc/config.gz verification (FAIL if device present but CONFIG_WATCHDOG=n); skip when device absent (tinyconfig, allnoconfig) |
| `400_perf-events` | perf_event_open(PERF_TYPE_SOFTWARE/TASK_CLOCK) via C helper; non-zero counter verified; skip if binary absent or CONFIG_PERF_EVENTS=n; opportunistic starfive-starlink-pmu sysfs check (ok on real VF2, skip in QEMU) |
| `410_arena-memory` | Arena allocator: alloc/reset/destroy correctness; pointer alignment (8-byte on 64-bit, 4-byte on i386); page-size block overflow; 32 MiB write stress; skip if binary absent |
| `420_32bit-boundary` | lseek64 >4 GiB on tmpfs (VFS off_t truncation class) + 128 MiB anonymous mmap write-read-back; skip if /tmp not writable or mmap fails; skip if binary absent |
| `430_seccomp` | seccomp-filter enforcement: BPF filter blocks SYS_getpid (ENOSYS); skip if CONFIG_SECCOMP_FILTER absent (ENOSYS/EINVAL); skip if binary absent |
| `440_io-uring` | Raw io_uring NOP SQE→CQE round-trip: setup ring, submit NOP, read CQE, verify res=0 user_data=0x42; skip if CONFIG_IO_URING absent (ENOSYS/EPERM); skip if binary absent |
| `450_fd-ipc` | timerfd one-shot expiry + eventfd write/read=7 + signalfd SIGUSR1 receive; core kernel features, always available; skip if binary absent |
| `460_unix-socket` | AF_UNIX socketpair SOCK_STREAM send/recv round-trip; skip if CONFIG_UNIX absent (EAFNOSUPPORT); skip if binary absent |
| `470_landlock` | Landlock ABI version check + ruleset create + restrict path + verify open(/proc/version) blocked (EACCES); skip if CONFIG_SECURITY_LANDLOCK absent (ENOSYS); skip if binary absent |
| `480_snapshot` | On-board system snapshot: validates /tmp/snapshot.txt written by /init at boot; checks SNAPSHOT header + 27 fields (identity: HOSTNAME/UNAME/INIT; system: UPTIME/LOADAVG/PAGESIZE/CLOCKSOURCE; memory: MEMORY/KERNELMEM/HUGEPAGES/SWAP; cpu: CPU/FLAGS; security: LSM/ASLR/DMESG_RESTRICT/KPTR_RESTRICT/TAINTED; kernel: SCHEDSTATS/CGROUP_CTRL/ENTROPY/#MODULES/FS/DMESG/ISSUES/CMDLINE); ISSUES: 0 at boot (exit 0=clean 1-254=issue-count 255=infra-fail); SCHEDSTATS/CGROUP_CTRL silently skipped if absent; skip if binary absent |
| `490_bpf` | eBPF socket filter: `bpf(BPF_PROG_LOAD, SOCKET_FILTER)` with minimal 2-insn program (MOV r0=0; EXIT); verifies BPF verifier acceptance and JIT/interpreter path; skip if binary absent or CONFIG_BPF_SYSCALL=n (ENOSYS/EPERM) |
| `500_sysvipc` | System V IPC: shmget/shmat/shmdt/shmctl (write+read 4096-byte segment); semget/semop V+P/semctl; msgget/msgsnd/msgrcv/msgctl; skip if binary absent or /proc/sysvipc absent (CONFIG_SYSVIPC=n) |

Next available slot: **510_** — 52 total (tests/001_smoke.sh + tests/custom/*.sh)

---

## Config Coverage (typical)

| Group | defconfig | tinyconfig | allnoconfig | rand500 | randdef |
|---|---|---|---|---|---|
| 001–050 | PASS | PASS/skip | PASS/skip | varies | PASS |
| 060–090 | PASS | skip | skip | varies | PASS |
| 100 network | PASS | skip | skip | varies | PASS |
| 110–130 | PASS | PASS | PASS | PASS | PASS |
| 140 sysctl | PASS | skip | skip | varies | PASS |
| 150–190 | PASS | PASS/skip | PASS/skip | varies | PASS |
| 260 vfs-links | PASS | PASS | PASS | PASS | PASS |
| 270 proc-sys-vm | PASS | skip | skip | varies | PASS |
| 280 proc-self | PASS | skip | skip | varies | PASS |
| 290–360 ns-* | PASS (ns configs) | skip | skip | skip | skip |
| 370 riscv-isa | skip | skip | skip | skip | skip |
| 380 arm64-features | skip | skip | skip | skip | skip |
| 390 watchdog | PASS | skip | skip | varies | skip |
| 400 perf-events | PASS | skip | skip | varies | PASS |
| 410 arena-memory | PASS | PASS | PASS | PASS | PASS |
| 420 32bit-boundary | PASS | PASS/skip | PASS/skip | varies | PASS |
| 430 seccomp | PASS | skip | skip | varies | PASS |
| 440 io-uring | PASS | skip | skip | varies | PASS |
| 450 fd-ipc | PASS | PASS | PASS | PASS | PASS |
| 460 unix-socket | PASS | skip | skip | varies | PASS |
| 470 landlock | PASS | skip | skip | varies | skip |
| 480 snapshot | PASS | PASS | PASS | PASS | PASS |

`varies` = depends on which 500 options were sampled. i386 passes all non-skipped tests.
290–360 require an ns-variant config (*nsconfig); skip via `/tests/ns-enabled` marker on tinyconfig/allnoconfig/defconfig/kunitconfig etc.
370/380 skip on all non-riscv/non-arm64 arches (x86_64, i386 runs always skip).
390 watchdog: guarded by `/tests/watchdog-enabled` marker (written when CONFIG_WATCHDOG=y in .config); PASS on defconfig/kunitconfig; skip on tinyconfig/allnoconfig/randdefconfig.
400 guarded by `/tests/perf-enabled` marker (written when perf-event binary present); requires CONFIG_PERF_EVENTS=y (present in defconfig/randdef, absent in tinyconfig/allnoconfig).
410 guarded by `/tests/arena-enabled` marker (written when arena-test binary present).
420–470 guarded by syscall-tests binary presence (no capability marker; subcommands skip individually at runtime when required syscall is absent).
480 guarded by snapshot binary presence (no capability marker; uname/proc/syslog always available); /init writes /tmp/snapshot.txt at boot before the test loop.

---

## How to Add a Test

1. Create `tests/custom/420_name.sh` (next slot) — make executable: `chmod +x`
2. Pattern:
```sh
#!/bin/sh
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -r /some/file ] || { skip "not available"; exit 0; }
[ -r /path ] && ok "readable" || fail "not readable"
[ $fails -eq 0 ] || exit 1
```
3. Avoid Toybox sh pitfalls — see `memory/code-quality.md`
4. If the test depends on a config capability (ns, watchdog, perf, arena): check the matching `/tests/<feature>-enabled` marker as the *first* guard; runtime probing follows as the second guard (double-guard pattern)
5. Update this file and `CLAUDE.md` Key files table
