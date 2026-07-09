#!/bin/bash
# Fetch the latest Linux -rc tag from upstream and write the version to
# build/.kernel-version so other stages can read it without re-running git.
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_env KERNEL_TREE BUILD_DIR

[[ -d $KERNEL_TREE ]]      || die "KERNEL_TREE '$KERNEL_TREE' does not exist"
[[ -d $KERNEL_TREE/.git ]] || die "'$KERNEL_TREE' is not a git repository"

# Warn on a dirty tree — does not block the fetch
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

# For shallow clones the tagged commit may not be in the local object store.
# Fetch it explicitly with depth=1 before checking out.
if ! git -C "$KERNEL_TREE" cat-file -e "${LATEST_RC}^{commit}" 2>/dev/null; then
    info "Tag commit not in local history — fetching $LATEST_RC ..."
    git -C "$KERNEL_TREE" fetch --depth=1 origin "tag $LATEST_RC"
fi

# Record HEAD so we can restore the working tree if checkout goes wrong
PREV_HEAD=$(git -C "$KERNEL_TREE" rev-parse --verify HEAD 2>/dev/null || true)

if ! git -C "$KERNEL_TREE" checkout "$LATEST_RC"; then
    # Checkout may have wiped the working tree before failing — restore it
    if [[ -n $PREV_HEAD ]]; then
        warn "Checkout failed — restoring previous working tree ..."
        git -C "$KERNEL_TREE" checkout "$PREV_HEAD" -- . 2>/dev/null || true
    fi
    die "Failed to checkout $LATEST_RC"
fi

# Sanity-check that the working tree is actually populated
[[ -f "$KERNEL_TREE/Makefile" ]] || \
    die "Kernel Makefile missing after checkout of $LATEST_RC — tree may be incomplete. " \
        "Try: git -C $KERNEL_TREE checkout HEAD -- ."

mkdir -p "$BUILD_DIR"
printf '%s\n' "$LATEST_RC" > "$BUILD_DIR/.kernel-version"
info "Version recorded in $BUILD_DIR/.kernel-version"
