# ns-ipc SYSVIPC ENOSYS fix — Plan

Branch: `fix/ns-ipc-sysvipc-enosys`
Start date: 2026-08-16
Status: DONE

---

## Situation

`290_ns-uts-ipc` fails on `randdefconfig/riscv` when `CONFIG_SYSVIPC=n` is
one of the 300 randomly disabled options. `ns-ipc semop` calls `semget()`,
which returns ENOSYS when System V IPC is not compiled in. The binary exits
non-zero, so the shell test reports FAIL instead of skip.

---

## Problems to Solve

1. **`semget()` ENOSYS not handled** — `ns-ipc.c` gracefully skips when
   `/proc/sysvipc/sem` is absent, but only *after* a successful `semget()`.
   When `CONFIG_SYSVIPC=n`, `semget()` fails with ENOSYS before the fopen.

---

## Goals

1. `ns-ipc semop` exits 0 and prints a skip message when `CONFIG_SYSVIPC=n`.
2. No change to behaviour when SYSVIPC is present.

---

## Scope

Files changed:
- `tests/ns/ns-ipc.c` — add ENOSYS guard on `semget()` return

No changes to: test scripts, initramfs, bootstrap, CI.

---

## Non-goals

- General ENOSYS hardening for other ns-* binaries (each handles its own errors).

---

## Design decisions

### ENOSYS at semget(), not the shell test

The shell test calls `$NS_IPC semop > /dev/null 2>&1` and checks exit code.
Fixing the C binary (exit 0 + message on ENOSYS) is cleaner than adding a
config-probe in the shell script, which would require reading `/proc/config.gz`
or grepping the enabled marker — fragile on randdefconfig.

---

## Testing strategy

- **Regression:** `make ci-test` — existing ns-* CI tests unchanged.
- **Manual:** verify the fix does not change the happy path.

---

## Testing commands

```sh
# Build
make -C tests/ns

# CI (no regressions)
make ci-test

# Smoke (verify binary is injected and test passes)
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=randdefconfig ARCHS=riscv
```
