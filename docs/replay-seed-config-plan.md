# feat/replay-seed-config — Plan

Branch: `feat/replay-seed-config`
Start date: 2026-07-18

---

## Problem

When a config from `configs/archive_passed/` or `configs/archive_failed/` needs to be
retested with a newer kernel, there is no automated path. The user must manually copy
the archived `.config` file into the build directory and invoke the build pipeline with
the correct `CONFIGS=` and `ARCHS=` flags — error-prone and tedious.

---

## Proposed Solution

`make replay CONFIG_FILE=<path-to-archived-config>` parses the archive filename to extract
`config` and `arch`, then delegates to `make all NO_FETCH=1 CONFIGS=<config> ARCHS=<arch>
SEED_CONFIG=<abs-path>`. A new `SEED_CONFIG` environment variable in `lib/build.sh`
bypasses the normal kernel config-target step and seeds `build/<config>-<arch>/.config`
directly from the archived file, then runs `olddefconfig` to resolve any version drift.

---

## Filename Parsing

Archive filenames have the form:
```
kconfig-<config>-<arch>-<version>-<sha256>[–<reason>].config
```

Arch is always one of `x86_64`, `i386`, `arm64` — no hyphens — so parsing is unambiguous:
scan for a known arch token; everything before it is `config`, everything after is
`version-sha256[-reason]`.

---

## SEED_CONFIG in build.sh

A guard is inserted before the existing `if [[ $CONFIG == rand500config ]]` chain:

```bash
if [[ -n "${SEED_CONFIG:-}" ]]; then
    cp "$SEED_CONFIG" "$PWD/$OUT_DIR/.config"
    # olddefconfig resolves any version drift silently
    if ! kmake olddefconfig; then ...
fi
elif [[ $CONFIG == rand500config ]]; then
    ...
```

After the guard (or any branch), step 1b (config fragment application) runs as usual.

---

## Makefile Changes

| Item | Detail |
|---|---|
| `SEED_CONFIG ?=` | New user-settable variable (default empty) |
| `CONFIG_FILE ?=` | Archive path passed by user |
| `export SEED_CONFIG` | Inherited by `lib/build.sh` |
| `replay` target | Parses filename, warns on version mismatch, delegates to sub-make |
| `.PHONY` | Add `replay` |
| Help text | Add `replay` entry with example |

---

## Files Changed

| File | Change |
|---|---|
| `lib/build.sh` | Add `SEED_CONFIG` guard before config if/elif chain |
| `Makefile` | `SEED_CONFIG ?=`, `CONFIG_FILE ?=`, export, `replay` target, `.PHONY`, help |
| `CLAUDE.md` | Document `replay` and `SEED_CONFIG`/`CONFIG_FILE` variables |
| `memory/workflows.md` | Add `make replay` to Common Workflows |

---

## Decisions

1. **Parse filename, not index** — arch + config are embedded in the filename; no index
   lookup needed; works even when run in a clone that didn't generate the entry
2. **Warn on version mismatch, don't abort** — the point of replay is to test an old
   config on a new kernel; a mismatch is expected and useful to know about
3. **`olddefconfig` after seed** — handles any version drift non-interactively; same
   mechanism used by `localconfig` and `install.sh`
4. **`SEED_CONFIG` env var, not a build.sh arg** — keeps the build.sh CLI interface
   stable (positional args `CONFIG ARCH` unchanged); env var is the existing pattern
   for optional build-step overrides (cf. `NO_BUILD`, `V`)
5. **Delegates to `make all NO_FETCH=1`** — reuses the full pipeline; report is always
   written even if the build fails with the seeded config
