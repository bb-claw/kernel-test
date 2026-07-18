#!/bin/bash
# Fetch the latest state of the stable-rc branch and update build/.kernel-version.
#
# stable-rc uses a rolling branch (e.g. linux-7.1.y) — Greg KH announces
# release candidates on LKML but does not create git tags for them.
# After fetch, HEAD is reset to the branch tip and the version is read from
# the kernel Makefile fields (VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION).
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_env KERNEL_TREE BUILD_DIR STABLE_RC_BRANCH

[[ -d $KERNEL_TREE ]]      || die "KERNEL_TREE '$KERNEL_TREE' does not exist"
[[ -d $KERNEL_TREE/.git ]] || die "'$KERNEL_TREE' is not a git repository"

REMOTE_URL=$(git -C "$KERNEL_TREE" remote get-url origin 2>/dev/null || true)
if [[ "$REMOTE_URL" != *"linux-stable-rc"* && "$REMOTE_URL" != *"/stable-rc"* ]]; then
    die "STABLE_RC_BRANCH is set but origin remote '$REMOTE_URL'" \
        "does not look like a stable-rc tree (expected URL containing 'linux-stable-rc' or '/stable-rc')." \
        "Set KERNEL_TREE to the correct path or fix the remote."
fi

if ! git -C "$KERNEL_TREE" diff --quiet 2>/dev/null; then
    warn "Kernel tree has uncommitted changes — reset --hard FETCH_HEAD will discard them"
fi

GIT=( git -C "$KERNEL_TREE" -c http.lowSpeedLimit=0 -c http.lowSpeedTime=0 )

info "Fetching branch $STABLE_RC_BRANCH from origin ..."
"${GIT[@]}" fetch origin "$STABLE_RC_BRANCH" \
    || die "Failed to fetch $STABLE_RC_BRANCH from origin"

info "Resetting HEAD to FETCH_HEAD ..."
"${GIT[@]}" reset --hard FETCH_HEAD \
    || die "Failed to reset to FETCH_HEAD"

VERSION=$(read_kernel_makefile_version) \
    || die "Could not read version from $KERNEL_TREE/Makefile"

mkdir -p "$BUILD_DIR"
printf '%s\n' "$VERSION" > "$BUILD_DIR/.kernel-version"
info "Fetched $STABLE_RC_BRANCH → $VERSION"
