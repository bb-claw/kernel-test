# install-fast — Plan

Branch: `feat/install-fast`
Start date: 2026-10-25

---

## Situation

`make install` runs a full mkinitcpio + grub-mkconfig cycle (~2 min) after each
kernel build. During git bisect, where 7–8 builds and reboots are needed, this
overhead adds 15+ minutes to the total bisect time. The initramfs and GRUB entry
do not change between bisect steps — only the bzImage does.

---

## Problems to Solve

1. **Bisect turnaround is too slow** — each step requires `make install` which
   regenerates the initramfs and GRUB config even though neither changes during
   a bisect. With 7 steps this wastes ~14 minutes.

---

## Goals

1. `make install-fast CONFIGS=localconfig ARCHS=x86_64` copies only the bzImage
   to the existing `/boot/vmlinuz-kt-*` file and exits.
2. The target fails with a clear error when no prior `make install` has been run
   (no existing target file), preventing silent misuse.
3. No changes to `make install` behavior.

---

## Scope

Files/components changed:
- `lib/install-fast.sh` — new script: derive BOOT_SUFFIX, guard target exists, sudo cp bzImage
- `Makefile` — new `install-fast` target + help text
- `tests/ci/test-install-fast.sh` — CI tests (O1–O4)
- `scripts/dev-test.sh` — register O1–O4 in ci9_tests, bump total_paths
- `tests/ci/coverage-map.md` — add O-group entries

No changes to: `lib/install.sh`, GRUB script, mkinitcpio logic.

---

## Non-goals

- Support for non-x86_64 arches (install itself is x86_64-only).
- Automatic bzImage-only build (user calls `make -C KERNEL_TREE O=... bzImage` directly).

---

## Design decisions

### Guard: target file must already exist

`install-fast` derives the same `BOOT_SUFFIX` as `install.sh` and checks
`/boot/vmlinuz-$BOOT_SUFFIX` exists before copying. This ensures GRUB has an
entry and an initramfs exists for the target suffix. A missing file means
`make install` was never run — failing loudly prevents a silent no-op boot.

### No modules, no mkinitcpio, no grub-mkconfig

For bisect across stable-rc commits (232 commits, ~7 steps), USB enumeration
is handled by built-in drivers (xhci_hcd). Modules and initramfs do not change
between bisect steps. Skipping them reduces each step from ~2 min to ~3 seconds.

---

## Testing strategy

- **O1** — `install-fast` fails when bzImage is absent
- **O2** — `install-fast` fails when target `/boot/vmlinuz-*` is absent
- **O3** — `install-fast` copies bzImage to existing target
- **O4** — BOOT_SUFFIX derived correctly for stable-rc tree (kt- prefix, full version)

---

## Testing commands

```sh
make dev-test
# Expected: exit 0, ≥70% decision paths covered

make ci-test
# Expected: all tests pass including test-install-fast.sh
```
