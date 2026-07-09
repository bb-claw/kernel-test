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

# Disable git's low-speed timeout — kernel.org can be legitimately slow.
# The default (1000 bytes/sec for 20 s) is too aggressive for large repos.
GIT=( git -C "$KERNEL_TREE" -c http.lowSpeedLimit=0 -c http.lowSpeedTime=0 )

# ── Tag fetch with local fallback ─────────────────────────────────────────────

info "Fetching tags from origin in $KERNEL_TREE ..."
FETCH_OK=1
"${GIT[@]}" fetch --tags origin || FETCH_OK=0

if [[ $FETCH_OK -eq 0 ]]; then
    warn "Remote tag fetch failed — checking for existing local -rc tags ..."
fi

LATEST_RC=$(git -C "$KERNEL_TREE" tag -l 'v*-rc*' \
    --sort=-version:refname | head -1)

if [[ -z $LATEST_RC ]]; then
    die "No -rc tags found locally or remotely. " \
        "Ensure the kernel tree was cloned from Linus's tree and has network access."
fi

[[ $FETCH_OK -eq 1 ]] && info "Latest -rc tag: $LATEST_RC" \
                       || warn "Using best available local tag: $LATEST_RC"

# ── Checkout ──────────────────────────────────────────────────────────────────

# For shallow clones the tagged commit may not be in the local object store.
# Fetch it with depth=1 before checking out.
if ! git -C "$KERNEL_TREE" cat-file -e "${LATEST_RC}^{commit}" 2>/dev/null; then
    info "Tag commit not in local history — fetching $LATEST_RC ..."
    "${GIT[@]}" fetch --depth=1 origin "tag $LATEST_RC"
fi

# Record HEAD so we can restore the working tree if checkout goes wrong
PREV_HEAD=$(git -C "$KERNEL_TREE" rev-parse --verify HEAD 2>/dev/null || true)

if ! git -C "$KERNEL_TREE" checkout "$LATEST_RC"; then
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
