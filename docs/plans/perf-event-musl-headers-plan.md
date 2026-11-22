# perf-event: musl-gcc missing linux/perf_event.h

Branch: `fix/perf-event-musl-headers`
Status: DONE

## Problem

On Debian/Ubuntu (Hetzner staging), `make -C tests/programs/perf-event all` fails:

```
perf-event.c:7:10: fatal error: linux/perf_event.h: No such file or directory
```

`musl-gcc` uses only musl's include paths and does not search `/usr/include`,
where `linux-libc-dev` installs the kernel ABI headers. The cross-compilers
(`aarch64-linux-gnu-gcc`, `riscv64-linux-gnu-gcc`) and plain `gcc -m32` use
glibc and find the header without issue. Arch Linux is unaffected because the
Arch `musl` package symlinks the kernel headers differently.

## Fix

Remove the `#include <linux/perf_event.h>` dependency by vendoring the three
definitions actually used by the file:

- `PERF_TYPE_SOFTWARE` (= 1U)
- `PERF_COUNT_SW_TASK_CLOCK` (= 1ULL)
- `struct perf_event_attr` (minimal: type, size, config + 120-byte pad)

These are stable kernel ABI since Linux 2.6.31. The `size` field tells the
kernel how large our copy of the struct is; zero-initialising with `memset`
and setting only type/config/size is the documented usage.

## Verification

```sh
make -C tests/programs/perf-event clean all   # all 5 targets pass
bash tests/ci/test-perf-event.sh              # 8/8 pass
```
