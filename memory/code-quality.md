# Code Quality

## Git Hooks (activate once with `make hooks` or `make bootstrap`)

`git config core.hooksPath .githooks` enables three hooks:

| Hook | Trigger | Checks |
|---|---|---|
| `pre-commit` | every commit | shellcheck on staged `.sh` files; executable bit on staged `tests/**/*.sh`; guard against staged `build/` `cache/` `reports/` |
| `commit-msg` | every commit | conventional commit format: `<type>[(<scope>)]: <desc>` |
| `pre-push` | every push | shellcheck on all tracked `.sh` files; executable bit on all `tests/**/*.sh`; design doc check on `feat/*`/`fix/*` branches; memory file size (≤ 150 lines) |

Skip in emergencies only: `git commit --no-verify` / `git push --no-verify`

---

## Commit Message Format

```
<type>[(<scope>)]: <description>
```

Types: `feat` `fix` `docs` `refactor` `chore` `ci` `test` `style` `perf`

Examples:
- `feat: add 200_my-test.sh`
- `fix(180_timer): skip sleep on Toybox i686`
- `chore(hooks): add commit-msg conventional format check`
- `docs: update branch workflow in CLAUDE.md`

---

## When Creating a Branch

1. Name: `<type>/<kebab-slug>` (e.g. `feat/200-ipc-test`, `fix/190-scheduler-i386`)
2. Create `docs/<slug>-plan.md` from `docs/plan-template.md` — required for `feat/*` and `fix/*` (enforced by pre-push)
3. Open a PR to `main` — never commit directly to `main`

---

## Shell Style

- `#!/bin/bash` + `set -euo pipefail` on every lib script (`lib/`)
- `#!/bin/sh` on every test script — Toybox sh 0.8.9 (POSIX only)
- Functions: `lowercase_snake_case` · Constants: `UPPER_SNAKE_CASE`
- Quote all expansions: `"$VAR"`, `"${VAR:-default}"`
- No `[[ ]]` in test scripts — use `[ ]` (POSIX sh)

---

## Toybox sh 0.8.9 Pitfalls (test scripts)

- **`$_x` leading-underscore vars** → Toybox parses as `$_` + literal; use plain names (`fails`, not `_fails`)
- **`trap`** → not a builtin; use `/bin/kill` for cleanup
- **`kill` builtin** → only `kill -0 $$` works; use `/bin/kill` for all other signals
- **`sleep N` on i386** → Toybox i686 sleep exits non-zero; guard with `if sleep N; then ... else skip ...; fi`
- **`$(( ))` in while loops** → OOM in 512 MB VM; use `for i in 1 2 3 ... 20` instead
- **`dd if=FILE bs=N count=N`** → Toybox dd ignores key=value args; use `head -c N` instead

---

## Test Script Pattern

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

---

## Review Checklist (before opening a PR)

- [ ] `shellcheck --severity=warning` clean (pre-push does this automatically)
- [ ] All test scripts are executable (`ls -la tests/custom/`)
- [ ] `make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS="x86_64 i386"` passes
- [ ] New test: skip guard present for missing kernel options
- [ ] All error paths in lib scripts write `STATUS=FAIL` before `die`
- [ ] Memory files updated (`memory/test-inventory.md`, `memory/code-quality.md`)
- [ ] `CLAUDE.md` Key files table updated (new tests, lib changes)
- [ ] Design doc (`docs/<slug>-plan.md`) complete and accurate
