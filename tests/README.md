# tests/

All test content for the kernel-test harness: VM scripts, CI self-tests,
hardware verification, namespace binaries, and C helper programs.

## Directory structure

```
tests/
├── 001_smoke.sh        Boot smoke test — always runs first in the VM
├── custom/             Functional VM tests (POSIX sh, run inside QEMU)
├── ci/                 Harness self-tests (bash, no kernel/QEMU needed)
├── hardware/           Real-machine verification for localconfig boots
├── ns/                 C binaries for namespace regression tests
└── programs/           C helper programs injected into the initramfs
    ├── arena-test/     Arena allocator memory verification (410_arena-memory.sh)
    └── perf-event/     perf_event_open smoke test (400_perf-events.sh)
```

## Test tiers

| Tier | Where it runs | Language | How to run |
|---|---|---|---|
| `001_smoke.sh` + `custom/` | Inside the QEMU VM | POSIX sh (Toybox) | `make all` or `make test` |
| `hardware/` | On the physical machine | bash | `bash tests/hardware/verify.sh` |
| `ci/` | On the build host | bash | `make ci-test` |

## VM tests (`001_smoke.sh` + `custom/`)

Copied into the Toybox cpio initramfs by `lib/initramfs.sh` and run inside the
VM by `/init` in filename-sorted order. The runner emits structured markers that
`lib/vm.sh` counts:

```
> TEST RUN: 010_check-proc
ok: /proc/cpuinfo readable
< TEST PASS: 010_check-proc
```

**Rules — enforced by pre-push hook:**
- `#!/bin/sh` — Toybox sh only; no bash features
- No `awk` — not compiled into the Toybox binary; use `grep | cut`
- No `[[ ]]` — use `[ ]` (POSIX sh)
- No `elif` — Toybox 0.8.9 bug; use nested `if/else/fi`
- No `if out=$(cmd); then` — assignment always exits 0 in Toybox; use file redirect
- Exit 0 = pass, non-zero = fail; print `ok:` / `FAIL:` / `skip:` prefixes
- Skip + `exit 0` when a required kernel option is absent

See `memory/code-quality.md` for the full pitfall list.

## Adding a VM test

1. Pick the next available slot from `memory/test-inventory.md` (currently **420_**)
2. Create `tests/custom/420_my-test.sh` using the pattern below
3. `chmod +x tests/custom/420_my-test.sh`
4. Update `memory/test-inventory.md` (required by pre-commit hook)

```sh
#!/bin/sh
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -r /some/file ] || { skip "not available"; exit 0; }
if [ condition ]; then ok "thing works"; else fail "thing broken"; fi
[ $fails -eq 0 ] || exit 1
```
