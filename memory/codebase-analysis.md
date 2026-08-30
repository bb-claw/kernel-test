# Codebase Analysis Tools

## rtk — always use for shell commands

All shell commands are rewritten transparently via the Claude Code hook.
No explicit invocation needed. Saves ~87% of tokens on grep/find/git output.
Run `rtk gain` to see current savings.

## codegraph — use only for C source tasks

codegraph indexes only C files (tests/ns/, tests/programs/, modules/).
It has no Bash backend — lib/, scripts/, tests/custom/ are invisible to it.

**When to use:**

| Task | Command |
|---|---|
| Locate a symbol across ns-* / programs | `codegraph query <symbol>` |
| Scope blast radius before editing | `codegraph impact <symbol>` |
| Get a function + its callers in one shot | `codegraph node <function>` |
| Understand call paths for a C bug fix | `codegraph explore "<description>"` |

**When NOT to use:** any Bash task (fetch, build, VM tests, hooks, scripts).
The memory files already document the architecture — don't re-derive it.

**No multi-language alternative exists.** Verified Aug 2026: @optave/codegraph
claims 34 languages including Bash but ships extractors for C#/Go/JS/Java/PHP/
Python/Ruby/Rust only — no Bash, no C. callGraph covers Bash but not C. Use
`rtk grep` for Bash symbol lookup; it's fast enough.

**Index status:** 16 C files, 298 nodes, 732 edges (`codegraph status`).
Keep in sync after adding C files: `codegraph sync`.
