# Test Inventory

## How Tests Run

All scripts in `tests/001_smoke.sh` and `tests/custom/NNN_*.sh` are copied into
the initramfs at `/tests/` and run in filename-sorted order by `/init`.

Protocol:
```
> TEST RUN: <name>     # before script runs
< TEST PASS: <name>    # on exit 0
< TEST FAIL: <name>    # on non-zero exit
```

`vm.sh` counts `^< TEST PASS:` and `^< TEST FAIL:` lines → `TESTS_PASS`, `TESTS_FAIL`.

Exit convention: `0` = pass, non-zero = fail. Use `ok:` / `FAIL:` / `skip:` prefixes
for assertion output. `skip()` + `exit 0` to skip a test gracefully when the required
config option is absent.

---

## Test Scripts

### 001_smoke.sh — Boot smoke

Minimal: shell arithmetic, `/dev/null` writable, `/proc/version` contains "Linux", `/sys/kernel` present.
Always runs. Failure = fundamental kernel or initramfs problem.

### 010_check-proc.sh

`/proc` content: `/proc/version`, `/proc/cpuinfo` (processor entry), `/proc/meminfo` (MemTotal > 0),
`/proc/uptime`, `/proc/cmdline` (has `console=`), `/proc/filesystems`.
Skip: procfs not mounted.

### 020_check-sysfs.sh

`/sys` hierarchy: `/sys/kernel`, `/sys/block`, `/sys/class/net` presence.
Skip: sysfs not mounted.

### 030_check-dmesg.sh

dmesg output: kernel version string present, no early oops/panic lines.

### 040_check-devnodes.sh

`/dev` nodes: null, zero, console, urandom character devices present and correct type.

### 050_check-kernel.sh

Kernel version format in `/proc/version`, UTS fields, `/proc/sys/kernel` readability.

### 060_check-tmpfs.sh

Single-line tmpfs write/read round-trip via a temp file.
Skip: tmpfs not in `/proc/mounts`.

### 070_check-proc-interrupts.sh

`/proc/interrupts` readable and non-empty (at least one interrupt line).
Skip: not readable.

### 080_check-slabinfo.sh

`/proc/slabinfo` readable (requires `CONFIG_SLUB_DEBUG` or `CONFIG_SLAB_DEBUG`).
Skip gracefully when not available (tinyconfig/allnoconfig).

### 090_check-clocksource.sh

Active clocksource registered in dmesg (pattern: `Switched to clocksource`,
`clocksource.*registered`, `registered.*clocksource`, `using clocksource`).
Skip: dmesg not readable.

### 100_network-loopback.sh

Bring up `lo` via `ip link set lo up` (or `ifconfig lo up`), verify `127.0.0.1` assigned,
`ping -c1 -W2 127.0.0.1`.
Skip: `/proc/net` and `/sys/class/net` both absent (CONFIG_NET off).
**Kernel paths:** CONFIG_NET, CONFIG_INET, loopback driver, ICMP echo.

### 110_tmpfs-stress.sh

Write 1 MiB of zeros to tmpfs, verify size (1048576 bytes), read back, rm.
Then allocate 20 small files and delete them (inode allocation path).
Skip: tmpfs not mounted.
**Kernel paths:** page cache, slab allocator, VFS write path, inode allocation.

### 120_rng.sh

Read 512 bytes from `/dev/urandom`, verify count. Read 4096 bytes (one page), verify count.
Check `/dev/random` present.
Skip: `/dev/urandom` not a character device.
**Kernel paths:** CRNG output path, character device layer.

### 130_fork-exec.sh

Single fork+exec+wait (`sh -c 'exit 0'`), exit-code propagation (exit 42),
20 sequential fork/exec cycles, subprocess stdout capture, background child + `wait`.
Always runs (fork/exec is always available if init reached).
**Kernel paths:** process creation, CoW, exec, PID allocator, SIGCHLD, scheduler wakeup.

### 140_sysctl.sh

Read `kernel.pid_max` (> 0), `kernel.hostname` (non-empty), write/restore `kernel.hostname`,
read `kernel.panic` (numeric), read `vm.swappiness` (≤ 200).
Skip: `/proc/sys` not present.
**Kernel paths:** sysctl interface, kernel parameter subsystem.

---

## Per-Config Coverage

| Test | defconfig | tinyconfig | allnoconfig | rand500config | randdefconfig |
|---|---|---|---|---|---|
| 001_smoke | PASS | PASS | PASS | PASS | PASS |
| 010–050 | PASS | skip/PASS | skip/PASS | varies | PASS |
| 060 tmpfs | PASS | PASS | PASS | PASS | PASS |
| 070–090 | PASS | skip | skip | varies | PASS |
| 100 network | PASS | skip | skip | varies | PASS |
| 110 tmpfs-stress | PASS | PASS | PASS | PASS | PASS |
| 120 rng | PASS | PASS | PASS | PASS | PASS |
| 130 fork-exec | PASS | PASS | PASS | PASS | PASS |
| 140 sysctl | PASS | skip | skip | varies | PASS |

`varies` = depends on which 500 options were randomly sampled.

---

## How to Add a Test

1. Create `tests/custom/NNN_name.sh` — next available slot is **150_**
2. Leave gaps: 010, 020, … so new tests can be inserted without renaming
3. Make executable: `chmod +x tests/custom/150_name.sh`
4. Pattern:
```sh
#!/bin/sh
_fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

# Guard: skip if prerequisite absent
if [ ! -f /some/file ]; then
    skip "prerequisite missing"
    exit 0
fi

[ -r /path ] && ok "path readable" || fail "path not readable"

[ $_fails -eq 0 ] || exit 1
```
5. Update `memory/test-inventory.md` with the new entry
6. Update DESIGN.md example test count in the summary.txt sample
