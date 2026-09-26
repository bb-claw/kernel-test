# ns-time riscv vDSO Hang — Fix Plan

Branch: `fix/ns-time-riscv-vdso-hang`
Start date: 2026-09-26

---

## Problem

`350_ns-time` causes the defconfig/riscv QEMU VM to hang for the full 720 s timeout.
The VM boots, passes tests up to `340_ns-cgroup`, then stalls inside `350_ns-time`
with QEMU at 99% CPU. Only observed on QEMU 11.x; QEMU 10.x passes.

---

## Root Cause

**Hang subcommand:** `ns-time offset` (not `setns-mt` as previously noted in FINDINGS.md).

**Hang site:** `cmd_offset()` in `tests/ns/ns-time.c`, inside the forked child:

```c
pid_t child = fork();
if (child == 0) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);   /* ← HANG */
    _exit(ts.tv_sec >= 100 ? 0 : 1);
}
waitpid(child, &status, 0);               /* blocks forever */
```

**Mechanism:** On riscv, `clock_gettime(CLOCK_MONOTONIC)` is implemented via the vDSO.
The vDSO reads a per-namespace vvar page through a read-side seqlock spin loop:

```c
do {
    seq = vdso_read_begin(vdata);   /* spin if seq is odd (update in progress) */
    /* read clock data */
} while (vdso_read_retry(vdata, seq));
```

When `unshare(CLONE_NEWTIME)` + `write(timens_offsets, "monotonic 100 0")` are called,
the kernel updates the per-namespace vvar page using `vdso_write_begin/end` which bumps
the seqlock seq counter from even → odd → even.  Under QEMU 11.x riscv TCG, the kernel's
seqlock write (`smp_store_release` + `fence`) is not made visible to the child's vDSO
spin loop — the child reads an odd seq value and spins indefinitely.  QEMU 11.x changed
the riscv TCG memory model handling in a way that breaks this sequencing.

**Host specifics:**
| Host | QEMU version | Result |
|---|---|---|
| Laptop (AMD Ryzen 7 5800H, Manjaro) | 11.1.1 | HANG (720 s timeout) |
| Hetzner staging (Debian bookworm) | 10.0.2 | PASS |

**Why 99% CPU:** The guest is spinning in userspace vDSO code, not blocked on a
kernel syscall, so TCG emulates the spin at full speed.

**Audit:** Searched all `tests/ns/*.c` and `tests/programs/*/*.c` for `clock_gettime`.
Only one call exists — exactly the one being fixed. No other binaries are affected.

---

## Fix

Replace the bare libc `clock_gettime()` call with a raw Linux syscall in the child.
The raw syscall bypasses the vDSO entirely and calls the kernel directly, which applies
the timens offset correctly without any seqlock:

```c
/* Before (uses vDSO — spins under QEMU 11.x riscv TCG) */
if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
    _exit(1);

/* After (kernel syscall — bypasses vDSO seqlock) */
if (syscall(SYS_clock_gettime, CLOCK_MONOTONIC, &ts) < 0)
    _exit(1);
```

The kernel's `clock_gettime` syscall handler applies the timens offset correctly on all
QEMU versions, so the test still verifies the actual feature (offset applied to
CLOCK_MONOTONIC inside a time namespace).

---

## Files Changed

| File | Change |
|---|---|
| `tests/ns/ns-time.c` | Replace `clock_gettime()` with `syscall(SYS_clock_gettime, ...)` in `cmd_offset()` child |
| `tests/ci/test-ns-time-fix.sh` | New CI test: static grep + x86_64 integration run |
| `FINDINGS.md` | Correct root cause (offset not setns-mt, vDSO seqlock not nanosleep, QEMU 11.x specific) |
| `memory/code-quality.md` | Add pitfall: vDSO clock_gettime in timens → use syscall() under riscv TCG |

---

## Testing

```sh
make ci-test
# Expected: test-ns-time-fix.sh passes (static grep + x86_64 offset run)

make programs
# Rebuilds tests/ns/bin/ with the fixed binary

make all NO_FETCH=1 CONFIGS=defconfig ARCHS=riscv
# Expected on QEMU 11.x: defconfig/riscv completes without timeout
# Expected output: "ok: time: CLOCK_MONOTONIC +100s offset applied correctly"
```

---

## QEMU Upstream Bug Report (draft)

**Summary:** riscv TCG vDSO seqlock not coherent across timens offset write in QEMU 11.x

**Product:** QEMU  
**Component:** target/riscv TCG  
**Version:** 11.0.0 (regression vs 10.0.2)

**Steps to reproduce:**
1. Build a riscv64 kernel with `CONFIG_TIME_NS=y` (defconfig enables it)
2. Boot with `qemu-system-riscv64 -M virt -cpu rv64 -m 1G ...`
3. From within the guest, run a program that does:
   ```c
   unshare(CLONE_NEWTIME);
   write("/proc/self/timens_offsets", "monotonic 100 0\n");
   fork(); // child:
   clock_gettime(CLOCK_MONOTONIC, &ts); // ← hangs forever
   ```
4. QEMU process goes to 99% CPU; guest hangs indefinitely

**Expected:** `clock_gettime` returns in < 1 ms with ts.tv_sec ≥ 100

**Actual:** `clock_gettime` spins forever in vDSO seqlock; guest is stuck

**Root cause hypothesis:** The riscv TCG memory model does not faithfully propagate
`smp_store_release` + `fence` sequences across the seqlock write in the kernel's
timens vvar page update code, leaving the child's vDSO spin reading a stale odd seq
value.

**Workaround (for test harnesses):** Use `syscall(SYS_clock_gettime, ...)` to bypass
the vDSO.

**Bisect target:** first QEMU release where this regressed (between 10.0.2 and 11.0.0).
