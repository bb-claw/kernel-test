#!/bin/bash
# Initialise kernel-test-data/ from scratch (one-time setup).
# Prefer 'make bootstrap' on existing machines — it clones or pulls automatically.
# Usage: make init-data-repo   or   scripts/init-data-repo.sh <path>
set -euo pipefail

DATA_REPO="${1:?usage: init-data-repo.sh <path>}"

info() { printf '[init-data-repo] %s\n' "$*"; }

if [[ -d "$DATA_REPO/.git" ]]; then
    info "Already initialised: $DATA_REPO"
    info "Use 'make bootstrap' to pull the latest data."
    exit 0
fi

if [[ -e "$DATA_REPO" ]]; then
    printf '[init-data-repo] ERROR: %s exists but is not a git repo\n' "$DATA_REPO" >&2
    exit 1
fi

info "Initialising $DATA_REPO"
git init "$DATA_REPO"
mkdir -p "$DATA_REPO/reports" \
         "$DATA_REPO/configs/archive_passed" \
         "$DATA_REPO/configs/archive_failed" \
         "$DATA_REPO/consolidation" \
         "$DATA_REPO/dmesg"
printf 'consolidation/\n' > "$DATA_REPO/.gitignore"
git -C "$DATA_REPO" add .gitignore
git -C "$DATA_REPO" commit -m "chore: initial data repo structure"

info "Done. Next steps:"
printf '\n'
printf '  # Add the GitHub remote and push:\n'
printf '  git -C %s remote add origin git@github.com:bb-claw/kernel-test-data.git\n' "$DATA_REPO"
printf '  git -C %s push -u origin main\n' "$DATA_REPO"
printf '\n'
printf '  # Migrate existing configs from the harness repo (see docs/data-repo-plan.md)\n'
