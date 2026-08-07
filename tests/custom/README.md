# tests/custom/

Functional VM test scripts — run inside the QEMU/KVM virtual machine in
filename-sorted order after `001_smoke.sh`.

## Slot numbering

Scripts use a 3-digit prefix with deliberate gaps (010, 020, …) to allow
inserting related tests without renaming everything. Leave gaps of 10 between
unrelated areas.

| Range | Area |
|---|---|
| 001–090 | Basic kernel interfaces: proc, sysfs, dmesg, devnodes, clocksource |
| 100–110 | Network and filesystem stress |
| 120–190 | Core subsystems: RNG, fork/exec, sysctl, mmap, signals, pipes, timers, scheduler |
| 200–280 | Advanced subsystems: inotify, futex, proc-net, bind-mount, cgroups, VFS, vm, proc-self |
| 290–360 | Namespace regression tests (require ns-variant config + ns-* binaries) |
| 370–380 | Architecture-specific: RISC-V ISA string, ARM64 feature flags |
| 400–410 | C helper programs: perf_event_open, arena allocator |

Next available slot: **420_**

See `memory/test-inventory.md` for the full list of what each script tests.

## Rules

- `#!/bin/sh` shebang — Toybox 0.8.14 sh (POSIX only, no bash extensions)
- No `awk` — not compiled into the Toybox binary; use `grep | cut`
- No `[[ ]]` — use `[ ]`
- No `elif` — Toybox 0.8.9 bug; use nested `if/else/fi`
- No `if out=$(cmd); then` — assignment masks exit code; redirect to a file instead
- Guard with `skip` + `exit 0` when a required kernel option is absent
- Never write outside `/tmp` inside the VM

See `memory/code-quality.md` for the complete pitfall list.

## Pattern

```sh
#!/bin/sh
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -r /some/file ] || { skip "prerequisite absent"; exit 0; }

if [ condition ]; then ok "thing works"; else fail "thing broken"; fi

[ $fails -eq 0 ] || exit 1
```
