# tests/programs/perf-event/

Minimal `perf_event_open` smoke test.  Cross-compiled for all four architectures;
injected into the initramfs at `usr/bin/perf-event`.  Exercised by
`tests/custom/400_perf-events.sh`.

## What it tests

Opens a software perf event (`PERF_TYPE_SOFTWARE / PERF_COUNT_SW_TASK_CLOCK`),
burns a short busy loop, reads the counter, and exits 0 if the counter is greater
than zero.

This catches regressions where `CONFIG_PERF_EVENTS=y` is set but the syscall
returns an error or the counter stays at zero.

## Why `PERF_TYPE_SOFTWARE`?

Software events do not require a hardware PMU.  `PERF_COUNT_SW_TASK_CLOCK`
measures CPU time consumed by the calling task and works correctly in QEMU
TCG emulation (no hardware counters available).  This means the test runs on
all four architectures without any special QEMU configuration.

## Output

Prints a single line with the raw counter value, then exits:

```
count=<N>       # N > 0 on success
```

Exit 0 = success (counter > 0).  Exit 1 = failure (syscall error or zero count).

## Skip conditions (`400_perf-events.sh`)

The VM script skips this test when:
- `usr/bin/perf-event` is absent (binary not built — run `make bootstrap`)
- `CONFIG_PERF_EVENTS=n` in the running kernel (tinyconfig, allnoconfig)
- `/proc/sys/kernel/perf_event_paranoid` is missing (indicates no perf support)

## Build

```sh
make -C tests/programs/perf-event/ all   # all 4 arches
make -C tests/programs/perf-event/ clean
```
