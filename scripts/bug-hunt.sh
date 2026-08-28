#!/bin/bash
# Invoke Claude Code to find 3 high-severity bugs in this repository.
# Results are written to bug-hunt/findings-<timestamp>.md (gitignored).
# Usage: make bug-hunt  OR  scripts/bug-hunt.sh
# Override: MAX_MINUTES=30 (time limit)  MAX_TURNS=80 (agent turn cap)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MAX_MINUTES="${MAX_MINUTES:-30}"
MAX_TURNS="${MAX_TURNS:-80}"
INSTRUCTIONS="$REPO/scripts/bug-hunt-instructions.md"
OUT_DIR="$REPO/bug-hunt"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
OUT_FILE="$OUT_DIR/findings-${TIMESTAMP}.md"

command -v claude >/dev/null 2>&1 || {
    printf 'error: claude CLI not found in PATH\n' >&2
    printf 'Install from https://claude.ai/code, then re-run.\n' >&2
    exit 1
}

[[ -f $INSTRUCTIONS ]] || {
    printf 'error: instructions not found: %s\n' "$INSTRUCTIONS" >&2
    exit 1
}

mkdir -p "$OUT_DIR"
printf '[bug-hunt] %s  max=%dmin  turns=%d\n' "$TIMESTAMP" "$MAX_MINUTES" "$MAX_TURNS"
printf '[bug-hunt] output  → %s\n' "$OUT_FILE"

cd "$REPO"

# Run claude in non-interactive print mode; allow only read-only tools.
# Output is streamed to the terminal and captured to the findings file.
set +e
timeout $(( MAX_MINUTES * 60 )) \
    claude --max-turns "$MAX_TURNS" \
           --allowedTools "Bash,Read" \
           -p "$(cat "$INSTRUCTIONS")" \
    | tee "$OUT_FILE"
pipeline_rc=${PIPESTATUS[0]}
set -e

case $pipeline_rc in
    0)   printf '\n[bug-hunt] done — %s\n' "$OUT_FILE" ;;
    124) printf '\n[bug-hunt] timed out after %d min — partial results in %s\n' \
             "$MAX_MINUTES" "$OUT_FILE" ;;
    *)   printf '\n[bug-hunt] claude exited with code %d — see %s\n' \
             "$pipeline_rc" "$OUT_FILE" ;;
esac
