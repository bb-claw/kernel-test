# Arch-Specific Tests — Plan

Branch: `feat/arch-tests`
Start date: 2026-08-06

---

## Situation

The test suite runs identically on all four arches (x86_64, i386, arm64, riscv). It checks
generic kernel subsystems (proc, tmpfs, signals, namespaces) but nothing about
arch-specific kernel paths: ISA extension detection on RISC-V, SIMD/LSE on ARM64, or
the perf_event_open syscall path that the riscv PMU subsystem frequently regresses. These
are real regression surfaces — kernel patches to arch/riscv, arch/arm64, or
kernel/events/ can silently break them without any of the existing tests noticing.

---

## Problems to Solve

1. **No coverage of arch-specific kernel paths** — riscv ISA detection regressions, arm64
   feature flag regressions, and perf_event_open failures are invisible to the current suite.
2. **riscv PMU is actively developed and breaks frequently** — `PERF_TYPE_SOFTWARE`
   counters (`PERF_COUNT_SW_TASK_CLOCK`) work in QEMU TCG without hardware PMU, so a
   software-counter test catches syscall-path regressions today and catches real-silicon
   regressions on the VisionFive 2 without any code change.
3. **arm64 NEON and LSE are ARMv8+ mandatory** — any kernel regression that drops them
   from the `Features:` line would silently break userland; no test currently catches this.

---

## Goals

1. `370_riscv-isa.sh` — parse `/proc/cpuinfo` ISA string; verify base extensions I, M, A,
   F, D, C are present; skip on non-riscv.
2. `380_arm64-features.sh` — parse `/proc/cpuinfo` `Features:` line; verify NEON (`asimd`)
   and LSE (`atomics`) are present; skip on non-arm64.
3. `400_perf-events.sh` — verify `perf_event_paranoid` is readable; call `perf_event_open`
   via a small C helper binary; verify a non-zero counter value is returned; skip if helper
   absent or `CONFIG_PERF_EVENTS` absent.
4. `tests/programs/perf-event/` — C source + Makefile for the perf_event_open helper,
   cross-compiled for all four arches exactly like `tests/ns/`.
5. `lib/bootstrap.sh` + `lib/initramfs.sh` — compile and inject `perf-event` binary
   alongside the ns binaries.
6. `tests/ci/test-arch-scripts.sh` — Tier 2 CI test: shellcheck, executable bit, inventory
   coverage, and skip-guard correctness for each new script.
7. `memory/test-inventory.md` updated with slots 370, 380, 400.

---

## Scope

Files changed:
- `tests/custom/370_riscv-isa.sh` — new test script
- `tests/custom/380_arm64-features.sh` — new test script
- `tests/custom/400_perf-events.sh` — new test script
- `tests/programs/perf-event/perf-event.c` — perf_event_open helper source
- `tests/programs/perf-event/Makefile` — cross-compile for x86_64, i386, arm64, riscv
- `lib/bootstrap.sh` — add `make -C tests/programs/perf-event/` step
- `lib/initramfs.sh` — install `perf-event` binary into initramfs
- `tests/ci/test-arch-scripts.sh` — new CI test
- `memory/test-inventory.md` — add rows for 370, 380, 400; update next slot to 410

No changes to: `lib/vm.sh`, `lib/common.sh`, `lib/build.sh`, `lib/report.sh`, Makefile
targets, any existing test scripts.

---

## Non-goals

- No atomic instruction execution binary for riscv — the ISA string check is sufficient;
  executing `amoadd.w` adds toolchain complexity without additional regression signal on QEMU.
- No SVE, PAC, MTE, or BTI checks on arm64 — these are optional extensions; a missing entry
  is not a kernel regression. Only mandatory ARMv8+ features are checked.
- No hardware PMU test — `PERF_TYPE_HARDWARE` requires a working PMU driver; QEMU TCG has
  none. Software counters (`PERF_TYPE_SOFTWARE`) exercise the syscall path cleanly on QEMU.
- No `perf` userspace tool — not in Toybox; C helper binary is the only viable path.
- No i386/x86_64 arch-specific tests — their ISA extensions are not dynamically detected
  via `/proc/cpuinfo` in the same way; cpuid-based tests add little regression signal.

---

## Design Decisions

### Arch detection

`uname -m` in Toybox POSIX sh:

```sh
arch=$(uname -m)
[ "$arch" = "riscv64" ] || { skip "not riscv (arch=$arch)"; exit 0; }
[ "$arch" = "aarch64" ] || { skip "not arm64 (arch=$arch)"; exit 0; }
```

No `[[ ]]`, no `case` with numeric patterns (both Toybox pitfalls).

### RISC-V ISA string parsing

`/proc/cpuinfo` on riscv reports the ISA string as:

```
isa		: rv64imafdcsu_zicsr_zifencei_...
```

Multi-letter extensions (everything after the first `_`) are irrelevant for base-extension
checks. Strip them with `sed`, leaving `rv64imafdcsu`. Check each required letter with
`grep -q`:

```sh
isa=$(grep '^isa' /proc/cpuinfo | head -1 | cut -d: -f2)
base=$(printf '%s' "$isa" | sed 's/_[a-z].*//')   # rv64imafdcsu
for ext in i m a f d c; do
    printf '%s' "$base" | grep -q "$ext" \
        && ok "ISA extension $ext" || fail "ISA extension $ext"
done
```

`grep -q "$ext"` on a single letter matches anywhere in the base string. Since the base
string is `rv64` followed only by extension letters, a single-letter grep is unambiguous
(no digit or other character shares a letter with the standard extension set except 'r',
'v', and the digit; none of I/M/A/F/D/C overlap with those).

The `case` pitfall (Toybox arm64/riscv: `case "$val" in 3*)` fails on numeric strings)
does not apply here — we use `grep`, not `case`, for extension matching.

### ARM64 feature detection

`/proc/cpuinfo` on arm64 reports a space-separated feature list:

```
Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics ...
```

```sh
features=$(grep '^Features' /proc/cpuinfo | head -1 | cut -d: -f2)
printf '%s' "$features" | grep -qw 'asimd'   && ok "NEON (asimd)" || fail "NEON (asimd)"
printf '%s' "$features" | grep -qw 'atomics' && ok "LSE (atomics)" || fail "LSE (atomics)"
```

`grep -qw` uses word-boundary matching to avoid false positives (e.g. `asimddp` matching
`asimd`). Both `asimd` and `atomics` are mandatory per the ARMv8-A ISA; their absence in
the Features line is always a kernel regression, not a config option.

### perf_event_open C helper

`tests/programs/perf-event/perf-event.c` — a minimal static binary:

```c
#include <linux/perf_event.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>

int main(void) {
    struct perf_event_attr attr = {
        .type   = PERF_TYPE_SOFTWARE,
        .config = PERF_COUNT_SW_TASK_CLOCK,
        .size   = sizeof(attr),
    };
    int fd = syscall(SYS_perf_event_open, &attr, 0, -1, -1, 0);
    if (fd < 0) { perror("perf_event_open"); return 1; }
    uint64_t count = 0;
    for (volatile int i = 0; i < 100000; i++) {}  /* burn some cycles */
    read(fd, &count, sizeof(count));
    close(fd);
    printf("%llu\n", (unsigned long long)count);
    return count > 0 ? 0 : 1;
}
```

Exits 0 and prints the counter value if positive; exits 1 otherwise. The shell test reads
stdout and asserts the value is greater than zero.

Makefile mirrors `tests/ns/Makefile`: cross-compile for all four arches into
`tests/programs/perf-event/bin/<arch>/perf-event`.

`lib/bootstrap.sh` adds `make -C tests/programs/perf-event/` after the ns step.
`lib/initramfs.sh` installs `tests/programs/perf-event/bin/$ARCH_DIR/perf-event` to
`build/initramfs-$ARCH/usr/bin/` alongside the ns binaries.

### perf-events test skip logic

Three skip conditions (in order):

1. `perf-event` binary absent (binary not in initramfs — happens if bootstrap not run):
   `[ -x /usr/bin/perf-event ] || { skip "perf-event binary absent"; exit 0; }`
2. `CONFIG_PERF_EVENTS` absent (check `/proc/config.gz` if available; skip if absent):
   tinyconfig and allnoconfig will typically have `CONFIG_PERF_EVENTS=n` — this is
   expected; the skip makes the test safe on those configs.
3. `perf_event_paranoid` unreadable (kernel compiled without perf events entirely).

Checking `/proc/config.gz` requires `zcat` — available in Toybox. But `zcat
/proc/config.gz` on a kernel without `CONFIG_IKCONFIG_PROC=y` will fail. Guard with
`[ -r /proc/config.gz ]`.

### CI test strategy

`tests/ci/test-arch-scripts.sh` verifies:

1. **shellcheck** — each script passes `shellcheck --shell=sh --severity=warning`.
2. **Executable bit** — `[ -x tests/custom/370_riscv-isa.sh ]` etc.
3. **Inventory** — each slot (370, 380, 400) is present in `memory/test-inventory.md`.
4. **Skip guard on wrong arch** — source the skip-guard portion of each script in bash
   with `uname()` stubbed to return a wrong arch; assert exit code 0 and "skip" message
   on stdout.

Skip guard simulation (no QEMU required):

```bash
# Simulate non-riscv arch to verify 370 skip guard
uname() { echo "x86_64"; }; export -f uname
out=$(bash tests/custom/370_riscv-isa.sh 2>&1); rc=$?
assert_eq "$rc" "0" "exits 0 on non-riscv"
assert_contains "$out" "skip" "prints skip message"
unset -f uname
```

---

## Testing Strategy

- **QEMU riscv** — `make all NO_FETCH=1 CONFIGS=defconfig ARCHS=riscv` — verifies
  `370_riscv-isa.sh` passes on real riscv kernel output; QEMU TCG exposes the standard
  `rv64imafdc` ISA string, so all base extensions should be present.
- **QEMU arm64** — `make all NO_FETCH=1 CONFIGS=defconfig ARCHS=arm64` — verifies
  `380_arm64-features.sh` passes; QEMU exposes `asimd` and `atomics` on all ARMv8 models.
- **Skip on wrong arch** — `make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64` — both
  370 and 380 should emit `skip:` and exit 0; 400 should skip on tinyconfig
  (`CONFIG_PERF_EVENTS=n`).
- **Tier 2 CI** — `make ci-test` — `test-arch-scripts.sh` runs without QEMU; verifies
  shellcheck, executable bit, inventory, and skip guards.

---

## Testing Commands

```sh
# 1. Run new CI test in isolation
bash tests/ci/test-arch-scripts.sh

# 2. Full Tier 2 CI (no QEMU required)
make ci-test

# 3. Verify riscv test passes in QEMU
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=riscv

# 4. Verify arm64 test passes in QEMU
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=arm64

# 5. Verify arch tests skip cleanly on x86_64 tinyconfig
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=x86_64

# 6. Verify perf-events on defconfig x86_64 (CONFIG_PERF_EVENTS=y by default)
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64
```
