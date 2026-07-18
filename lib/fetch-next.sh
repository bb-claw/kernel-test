#!/bin/bash
# Fetch the latest state of linux-next (origin/master) and update build/.kernel-version.
#
# linux-next is a daily-rebased integration tree — patches land here before
# Linus pulls them into mainline.  It has no rc tags; HEAD is reset to the
# origin/master tip after each fetch.
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_env KERNEL_TREE BUILD_DIR

[[ -d $KERNEL_TREE ]]      || die "KERNEL_TREE '$KERNEL_TREE' does not exist"
[[ -d $KERNEL_TREE/.git ]] || die "'$KERNEL_TREE' is not a git repository"

REMOTE_URL=$(git -C "$KERNEL_TREE" remote get-url origin 2>/dev/null || true)
if [[ "$REMOTE_URL" != *"linux-next"* ]]; then
    die "LINUX_NEXT=1 is set but origin remote '$REMOTE_URL'" \
        "does not look like a linux-next tree (expected URL containing 'linux-next')." \
        "Set KERNEL_TREE to the correct path or fix the remote."
fi

if ! git -C "$KERNEL_TREE" diff --quiet 2>/dev/null; then
    warn "Kernel tree has uncommitted changes — reset --hard FETCH_HEAD will discard them"
fi

setup_git_array

info "Fetching origin/master from linux-next ..."
"${GIT[@]}" fetch origin master \
    || die "Failed to fetch master from origin"

reset_to_fetch_head
write_kernel_version
info "Fetched linux-next → $KERNEL_VERSION"
