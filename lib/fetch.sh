#!/bin/bash
# Fetch the latest Linux -rc tag from upstream and write the version to
# build/.kernel-version so other stages can read it without re-running git.
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_env KERNEL_TREE BUILD_DIR

[[ -d $KERNEL_TREE ]]     || die "KERNEL_TREE '$KERNEL_TREE' does not exist"
[[ -d $KERNEL_TREE/.git ]] || die "'$KERNEL_TREE' is not a git repository"

# Warn on a dirty tree — fetch will still succeed but test reproducibility suffers
if ! git -C "$KERNEL_TREE" diff --quiet 2>/dev/null; then
    warn "Kernel tree has uncommitted changes"
fi

info "Fetching tags from origin in $KERNEL_TREE ..."
git -C "$KERNEL_TREE" fetch --tags origin

# Pick the most recent -rc tag by version order
LATEST_RC=$(git -C "$KERNEL_TREE" tag -l 'v*-rc*' \
    --sort=-version:refname | head -1)

[[ -n $LATEST_RC ]] || die "No -rc tags found in $KERNEL_TREE"
info "Latest -rc tag: $LATEST_RC"

git -C "$KERNEL_TREE" checkout "$LATEST_RC"

mkdir -p "$BUILD_DIR"
printf '%s\n' "$LATEST_RC" > "$BUILD_DIR/.kernel-version"
info "Version recorded in $BUILD_DIR/.kernel-version"
