## What changed

<!-- One sentence: what does this PR add, fix, or change? -->

## Type

- [ ] `feat` — new test, config profile, or harness feature
- [ ] `fix` — bug in test script or lib script
- [ ] `docs` — CLAUDE.md / README only
- [ ] `chore` — hooks, tooling, CI

## Test run

- [ ] `make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS="x86_64 i386"` (quick smoke)
- [ ] `make all NO_FETCH=1 ARCHS="x86_64 i386"` (full suite — required for any change touching `tests/`)
- [ ] Not required (docs/chore only)

## Checklist

- [ ] Commit messages follow `<type>[(<scope>)]: <desc>` format (enforced by commit-msg hook)
- [ ] `shellcheck` clean — pre-push hook confirms
- [ ] No Toybox sh pitfalls (leading-underscore vars, `trap`, `sleep` on i386, `$(( ))` in while loops)
