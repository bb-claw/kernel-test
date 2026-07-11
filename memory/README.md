# memory/

Persistent project context for the Claude Code AI assistant. These files are
loaded automatically into the assistant's context at the start of each session
so knowledge carries over between conversations.

## Files

| File | Contents |
|---|---|
| `MEMORY.md` | Index — one-line pointer to every other memory file |
| `project.md` | Architecture, directory structure, key decisions, test protocol |
| `config-profiles.md` | All config profiles, their bases, fragments, and special handling |
| `test-inventory.md` | All test scripts, coverage matrix, next available slot |
| `workflows.md` | Make commands, variable table, common patterns |
| `code-quality.md` | Commit format, shell style rules, git hooks, review checklist |

## Not for humans

This directory is maintained by the AI assistant. For human-readable project
documentation see:

- `README.md` — user-facing overview and quick start
- `DESIGN.md` — architecture and implementation details
- `CLAUDE.md` — instructions and context for the AI assistant
