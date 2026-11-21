# fix/install-fast-boot-dir — Plan

Branch: `fix/install-fast-boot-dir`
Start date: 2026-11-21

---

## Situation

`tests/ci/test-install-fast.sh` has two test cases that invoke `lib/install-fast.sh`
directly without mocking `/boot`. When run from `kernel-test-stable-rc` via `make dev-test`,
the Makefile preset exports `LABEL=stable-rc`, which leaks into the subprocess. This causes
the script to construct a TARGET path (`/boot/vmlinuz-kt-localconfig-stable-rc-7.2.13-rc3-x86_64`)
that actually exists on the user's machine, so the script succeeds (and silently overwrites a
real boot file) instead of failing with the expected error message.

---

## Problems to Solve

1. **Leaked `LABEL` env var** — `presets/kernel-test-stable-rc.mk` sets `LABEL ?= stable-rc`;
   line 175 of the Makefile exports it. `install-fast.sh` respects an existing `LABEL` and skips
   derivation. The two tests that run the actual script without mocking `/boot` derive a TARGET
   that may already exist.
2. **O5b accidental boot-file overwrite** — the same issue causes O5b to overwrite the real
   `/boot/vmlinuz-kt-localconfig-stable-rc-7.2.13-rc3-x86_64` with "fake\n" content.

---

## Goals

- `make dev-test` passes all O1–O5 + last test cases regardless of which clone it runs from.
- Tests do not touch the real `/boot` directory.
- Production behaviour of `make install-fast` (which legitimately exports `LABEL`) is unchanged.

---

## Design Decisions

- Add `BOOT_DIR=${BOOT_DIR:-/boot}` to `lib/install-fast.sh` and use `$BOOT_DIR/vmlinuz-$BOOT_SUFFIX`
  as TARGET. Default is `/boot`, so production callers are unaffected.
- In the two affected tests (O5b and the last "make install" test), create an empty tmp dir and
  pass `BOOT_DIR="$tmp"`. The target cannot exist in an empty dir, so the die fires correctly.
- No changes to `Makefile` or preset files; `LABEL` leakage is expected and correct for real use.

---

## Testing Strategy

- `bash tests/ci/test-install-fast.sh` → 15/15 pass
- `LABEL=stable-rc bash tests/ci/test-install-fast.sh` → 15/15 pass (simulates dev-test env)
- `make dev-test` in `kernel-test-stable-rc` → no O1–O5 failures
