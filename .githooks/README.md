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

### `pre-push` — all tracked files (thorough)

Runs on every `git push`. Full-repo sweep:

- **shellcheck** `--severity=warning` on all tracked `.sh` files
- **Executable bit** on all `tests/**/*.sh` scripts

## Skipping (emergencies only)

```sh
git commit --no-verify
git push --no-verify
```
