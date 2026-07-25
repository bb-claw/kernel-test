# .githooks/

Git hooks for this repository. Activated via:

```sh
make hooks        # hooks only
make bootstrap    # hooks + package install
```

This runs `git config core.hooksPath .githooks`, pointing Git at this directory
instead of the default `.git/hooks/`.

## Hooks

### `pre-commit` — staged files only (fast)

Runs on every `git commit`. Checks only what is about to be committed:

- **shellcheck** `--severity=warning` on staged `.sh` files
- **Executable bit** on staged `tests/**/*.sh` scripts
- **Artifact guard** — blocks staging of files under `build/`, `cache/`, `reports/`
- **Inventory sync** — when a new test script is staged, `memory/test-inventory.md` must also be staged

### `commit-msg` — commit message format

Runs on every `git commit`. Enforces conventional commit format:

```
<type>[(<scope>)]: <description>
```

Types: `feat` `fix` `docs` `refactor` `chore` `ci` `test` `style` `perf`

### `pre-push` — all tracked files (thorough)

Runs on every `git push`. Full-repo sweep:

- **shellcheck** `--severity=warning` on all tracked `.sh` files
- **Executable bit** on all `tests/**/*.sh` scripts
- **Inventory coverage** — every `tests/custom/*.sh` and `tests/001_smoke.sh` must appear in `memory/test-inventory.md`
- **Design doc** — `feat/*` and `fix/*` branches must have a `docs/<slug>-plan.md`
- **Memory file sizes** — every `memory/*.md` (except `MEMORY.md`) must be ≤ 150 lines
- **`awk` ban** — VM test scripts (`tests/custom/*.sh`, `tests/001_smoke.sh`) must not call `awk`; use `grep | cut` instead

## Skipping (emergencies only)

```sh
git commit --no-verify
git push --no-verify
```
