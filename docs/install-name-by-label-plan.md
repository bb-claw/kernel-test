# install: name kernel by label+version — Plan

Branch: `feat/install-name-by-label`
Start date: 2026-08-25

---

## Situation

`lib/install.sh` names all installed kernels `vmlinuz-localconfig-x86_64` regardless of
which clone or series they were built from. Running `make install` in any of the six clones
overwrites the same file. With dedicated per-series clones (kernel-test, kernel-test-stable-rc-7.1,
kernel-test-stable-rc-7.2, …) now in place, each clone should produce a distinct, human-readable
kernel name encoding its series and major.minor.

---

## Problems to Solve

1. **All installs collide** — `vmlinuz-localconfig-x86_64` is overwritten on every install regardless of series.
2. **Name is not human-readable** — `localconfig-x86_64` encodes the config profile, not the series.

---

## Goals

1. `make install` in `kernel-test` (mainline 7.2) → `/boot/vmlinuz-localconfig-mainline-7.2-x86_64`
2. `make install` in `kernel-test-stable-rc-7.1` → `/boot/vmlinuz-localconfig-stable-rc-7.1-x86_64`
3. `make install` in `kernel-test-stable-rc-7.2` → `/boot/vmlinuz-localconfig-stable-rc-7.2-x86_64`
4. `make install` in `kernel-test-stable` → `/boot/vmlinuz-localconfig-stable-7.1-x86_64`
5. Matching initramfs, System.map, mkinitcpio preset names use the same suffix
6. No `x86_64` suffix needed (install is x86_64-only, enforced by the script)

---

## Scope

Files changed:
- `lib/install.sh` — compute `BOOT_SUFFIX` from `LABEL + major.minor` instead of `CONFIG-ARCH`

No changes to: `Makefile`, presets, config fragments, build pipeline, QEMU test pipeline.

---

## Non-goals

- `CONFIG_LOCALVERSION` in the kernel config — `uname -r` still shows `-localconfig`; that's a separate cosmetic concern
- Any install name override variable — auto-derivation is sufficient; label is set per-clone in the preset

---

## Design decisions

### Derive name from LABEL + kernel major.minor

`LABEL` is already exported from the Makefile and set by each preset (`stable-rc`, `mainline`, etc.).
`KVER` (from `include/config/kernel.release`) always starts with `X.Y`, extractable via grep.

`BOOT_SUFFIX="${LABEL}-${MAJOR_MINOR}"` gives:
- `mainline-7.2`, `stable-rc-7.1`, `stable-rc-7.2`, `stable-7.1`

When `LABEL` is empty (no preset, localconfig build without a preset), fall back to the same
LABEL auto-detection logic as `report.sh` (STABLE_RELEASE→stable, linux-next→linux-next, else mainline).

### Drop `-x86_64` from BOOT_SUFFIX

`install.sh` already enforces x86_64-only. The arch is implicit and adds noise to `/boot` filenames.

### mkinitcpio preset renamed to BOOT_SUFFIX

`mkinitcpio -p mainline-7.2` reads `/etc/mkinitcpio.d/mainline-7.2.preset`. Existing
`localconfig.preset` is not touched — it remains valid for kernels installed before this change.

---

## Testing strategy

- **Build + install** — `make install CONFIGS=localconfig ARCHS=x86_64` in each clone; verify `/boot/vmlinuz-<label>-<major.minor>` exists
- **No QEMU test** — install.sh is host-side only; behavior is verified by the sanity checks it already runs (step 9)
- **No CI test added** — install.sh requires sudo + real Arch/Manjaro host; not testable in CI

---

## Testing commands

```sh
make dev-test

# After make local in kernel-test-stable-rc-7.2:
make install CONFIGS=localconfig ARCHS=x86_64
# Expected: /boot/vmlinuz-stable-rc-7.2  /boot/initramfs-stable-rc-7.2.img

# In kernel-test (mainline):
make install CONFIGS=localconfig ARCHS=x86_64
# Expected: /boot/vmlinuz-mainline-7.2  /boot/initramfs-mainline-7.2.img
```
