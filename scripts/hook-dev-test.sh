#!/bin/bash
# Toggle dev-test integration in .githooks/pre-push.
# Running once installs; running again removes. Per-machine opt-in.
set -euo pipefail

HOOK="$(git rev-parse --show-toplevel)/.githooks/pre-push"
MARKER='# dev-test-hook-begin'
END_MARKER='# dev-test-hook-end'

if grep -qF "$MARKER" "$HOOK" 2>/dev/null; then
    # Remove the block
    sed -i "/$MARKER/,/$END_MARKER/d" "$HOOK"
    printf '[hook-dev-test] removed dev-test from pre-push\n'
else
    # Append the block before the final exit line
    cat >> "$HOOK" <<'EOF'

# dev-test-hook-begin
# Installed by: make hook-dev-test  (remove by running make hook-dev-test again)
printf '[pre-push] running dev-test gate...\n'
if ! make -C "$(git rev-parse --show-toplevel)" dev-test; then
    printf '[pre-push] dev-test FAILED — push blocked\n'
    exit 1
fi
# dev-test-hook-end
EOF
    printf '[hook-dev-test] installed dev-test in pre-push\n'
    printf '[hook-dev-test] run again to remove\n'
fi
