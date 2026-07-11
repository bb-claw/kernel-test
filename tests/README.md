# tests/

Test scripts that run inside the QEMU/KVM virtual machine, plus hardware
verification for real-machine boots.

## Structure

```
tests/
├── 001_smoke.sh          # Boot smoke test — always runs first
├── custom/               # Functional kernel-path tests (QEMU)
│   ├── 010_check-proc.sh
│   ├── 020_check-sysfs.sh
│   └── ...               # run in NNN_ filename order
└── hardware/             # Real-hardware verification (run on the physical laptop)
    └── verify.sh
```

## QEMU tests (`001_smoke.sh` + `custom/`)

Injected into the BusyBox initramfs by `lib/initramfs.sh` and run inside the VM
by `/init`. The `/init` runner emits structured markers that `lib/vm.sh` counts:

```
> TEST RUN: 010_check-proc
ok: /proc/cpuinfo readable
< TEST PASS: 010_check-proc
```

**Rules for QEMU test scripts:**
- `#!/bin/sh` — BusyBox sh only; no bash features
- Exit 0 = pass, non-zero = fail
- Use `ok:` / `FAIL:` / `skip:` prefixes for all assertion output
- Guard with `skip` + `exit 0` when a required kernel option is absent
- Never write outside `/tmp` inside the VM

## Hardware tests (`hardware/`)

Run on the physical machine after booting a custom kernel (e.g. `localconfig`).
Use bash — not BusyBox. Same `ok:` / `FAIL:` / `skip:` output format.

```sh
bash ~/git/kernel-test/tests/hardware/verify.sh
```

## Adding a QEMU test

1. Create `tests/custom/NNN_my-test.sh` (3-digit prefix, leave gaps: 010, 020…)
2. `chmod +x tests/custom/NNN_my-test.sh`
3. Next available slot: `150_`
