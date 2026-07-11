# Code Quality

Adapted from homelab `code-quality.md` for this Bash-only project.

---

## Git Hooks (automatic — activate once)

```sh
make hooks        # or: make bootstrap (also installs packages)
```

Sets `git config core.hooksPath .githooks`.

| Hook | Trigger | Scope | Checks |
|---|---|---|---|
| `pre-commit` | every commit | staged files only | shellcheck on staged `.sh` files; executable bit on staged `tests/**/*.sh`; guard against staged `build/` `cache/` `reports/` |
| `pre-push` | every push | all tracked files | shellcheck on all tracked `.sh` files; executable bit on all `tests/**/*.sh` |

Skip in emergencies only: `git commit --no-verify` / `git push --no-verify`

---

## Commit Message Format

```
<type>: <description>
```

Types: `feat` `fix` `docs` `refactor` `chore` `test`

Examples:
- `feat: add randdefconfig profile with 300 random disables`
- `fix: exclude sanitizers from randconfig to prevent false boot failures`
- `docs: update DESIGN.md config profile table`
- `test: add network loopback and fork-exec functional tests`
- `refactor: rename rand100config to rand500config`

No scope needed for a single-purpose repo. Keep description under 72 chars.

---

## Before Every Commit

1. **Shell scripts:** no `bash`-isms in `tests/` (they run under `sh` inside BusyBox); `#!/bin/bash` only in `lib/`
2. **Executable bit:** `chmod +x` on new test scripts
3. **No hardcoded paths:** use `KERNEL_TREE`, `BUILD_DIR`, `REPORT_DIR`, `OUT_DIR`
4. **Configs:** new config profiles need a fragment in `configs/<name>.config` if bootable; add to `CONFIGS` in Makefile
5. **Memory files:** update `memory/` for any new test, config profile, or workflow change

---

## Shell Style Rules (lib/ scripts)

- `#!/bin/bash` + `set -euo pipefail` on every lib script
- `#!/bin/sh` on every test script (BusyBox sh, POSIX only)
- Functions: `lowercase_snake_case`
- Constants: `UPPER_SNAKE_CASE`
- Quote all variable expansions: `"$VAR"`, `"${VAR:-default}"`
- No `[[ ]]` in test scripts — use `[ ]` (POSIX)
- Error paths write `STATUS=FAIL` to status file before calling `die`
- Never `cd` inside lib scripts — use absolute paths via `$PWD/$OUT_DIR`

---

## Test Script Rules

- Exit 0 = pass, non-zero = fail
- Use `ok:` / `FAIL:` / `skip:` prefixes for all assertions
- Increment `_fails` on every `fail()`, exit with `[ $_fails -eq 0 ] || exit 1`
- Guard with skip+exit 0 when the required kernel option is absent
- Never write to `/` or outside `/tmp` inside the VM
- No `bash` features — `[ ]` not `[[ ]]`, no `$()` pipelines with `|&`, no arrays

---

## Before Updating MD Files

Check that these are in sync after any change:
- Config profile added/renamed → `CLAUDE.md` Key files + Tech stack, `README.md` profiles table, `DESIGN.md` build tree + example report, `memory/config-profiles.md`
- Test added → `CLAUDE.md` Key files, `README.md` directory layout, `DESIGN.md` example test counts, `memory/test-inventory.md`
- Workflow changed → `CLAUDE.md` Running locally, `README.md` examples, `memory/workflows.md`

---

## Review Checklist (before PR / before pushing)

From homelab `review-checklist.md` — generic items applicable here:

**Quality gates:**
- [ ] `shellcheck --severity=warning lib/*.sh tests/001_smoke.sh tests/custom/*.sh` — no warnings
- [ ] All test scripts are executable (`ls -la tests/custom/`)
- [ ] `make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64` passes locally

**Code correctness:**
- [ ] New config profile: fragment applied last so bootability options always win
- [ ] New test: skip guard present for missing kernel options
- [ ] Status files: all exit paths write STATUS= before dying
- [ ] No new hardcoded paths introduced

**Docs:**
- [ ] MD files updated (see "Before Updating MD Files" above)
- [ ] memory/ files updated

**Scope:**
- [ ] Diff contains only what was intended — no unrelated changes
