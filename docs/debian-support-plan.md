# Debian Support Plan (`feat/debian-support`)

## Problem

`lib/bootstrap.sh` was written and tested on Arch/Manjaro. Running it on Debian
bookworm (the OS on Hetzner-staging) fails or produces an incomplete environment:

| Issue | Root cause |
|---|---|
| `gcc-riscv64-linux-gnu` not installed | missing from apt block |
| `libssl-dev` missing | needed by kernel configs with `CONFIG_SYSTEM_TRUSTED_KEYS` |
| `dwarves` (pahole) version 1.24 | bookworm ships 1.24; kernels ≥6.0 require ≥1.25 for BTF |
| `qemu-system-riscv64` not guaranteed | `qemu-system-misc` not in original apt block |
| All `sudo` calls fail when run as root | Ansible on Hetzner runs bootstrap as root |
| REQUIRED check misses cross-compilers | `aarch64-linux-gnu-gcc`, `riscv64-linux-gnu-gcc` not verified |

## Changes to `lib/bootstrap.sh`

### 1. Root vs sudo (golden door-knob)

```bash
if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
```

All privileged calls use `$SUDO`. Root callers (Ansible) get no-op `$SUDO`;
regular users get `sudo` as before. The `kvm` group setup is skipped when root.

### 2. Debian apt block

- Add `gcc-riscv64-linux-gnu` — riscv cross-compiler
- Keep `gcc-multilib` — required for `gcc -m32` (i386 kernel builds)
- Add `libssl-dev` — kernel `CONFIG_SYSTEM_TRUSTED_KEYS` dependency
- Detect `VERSION_CODENAME` from `/etc/os-release` and add
  `${CODENAME}-backports` to apt sources (idempotent — skips if already present)
- Install `dwarves` and `qemu-system-misc` via `-t ${CODENAME}-backports`

Backports rationale:
- **dwarves**: bookworm ships 1.24; backports provides 1.25+ needed for BTF
- **qemu-system-misc**: provides `qemu-system-riscv64`; backports version
  is tested against recent kernels and preferred over the bookworm default

### 3. REQUIRED check — dynamic, arch-gated

Current REQUIRED array always checks all four QEMU binaries and misses
cross-compilers. New behaviour: build the list from the `ARCHS` argument:

```
x86_64 → qemu-system-x86_64
i386   → qemu-system-i386
arm64  → qemu-system-aarch64  aarch64-linux-gnu-gcc
riscv  → qemu-system-riscv64  riscv64-linux-gnu-gcc
```

Core tools (gcc, make, ccache, cpio, git, bc, flex, bison, lzop) always checked.

### 4. pahole version check

After install, verify `pahole --version ≥ 1.25`. Warn with a backports hint
if the version is too old. Non-fatal — build may succeed on configs that do
not enable BTF.

### 5. gcc -m32 warning updated

Added Debian hint: `sudo apt-get install gcc-multilib`.

## Hetzner-staging deployment notes

### Environment

| Property | Value |
|---|---|
| OS | Debian GNU/Linux 12 (bookworm) |
| CPU | x86_64 (no `/dev/kvm` — TCG only) |
| Automation | Ansible deploys repo; systemd timer calls `make` |

### No KVM — TCG timing

Without KVM, QEMU runs in TCG software emulation. `vm.sh` already warns per
boot and arm64/riscv always use TCG. Observed rough timing at TCG:

| Arch | Approx boot time |
|---|---|
| x86_64 / i386 | 60–120 s |
| arm64 | 120–240 s |
| riscv | 180–360 s |

`TIMEOUT` (default 300 s) and `VM_TIMEOUT` (300 s; ×2 for arm64/riscv) should
be sufficient. If boots time out, raise via `make all TIMEOUT=600`.

### Recommended cron / systemd timer pattern

**Phase 1 — build-only (current state, no KVM confirmed):**

```sh
# /etc/systemd/system/kernel-test.service
ExecStart=/usr/bin/make -C /home/mainuser/git/kernel-test-stable-rc \
    all NO_BUILD=0 TIMEOUT=600 \
    CONFIGS="defconfig tinyconfig allnoconfig" ARCHS="x86_64 i386 arm64 riscv"
```

Skip VM tests by setting `VM_ONLY=` targets … actually: run `make build` only
until TCG feasibility is confirmed:

```sh
make fetch-stable-rc
make build CONFIGS="defconfig tinyconfig" ARCHS="x86_64 i386 arm64 riscv"
make report
```

**Phase 2 — full pipeline (after TCG confirmed viable):**

```sh
make all NO_FETCH=1 CONFIGS="defconfig tinyconfig" ARCHS="x86_64 i386"
make all NO_FETCH=1 CONFIGS="defconfig" ARCHS="arm64 riscv" TIMEOUT=600
```

### Bootstrap invocation (Ansible / one-time setup)

```sh
# As root (Ansible):
cd /home/mainuser/git/kernel-test-stable-rc
make bootstrap

# As regular user:
make bootstrap
```

Both are safe; the `SUDO` detection handles either context.
