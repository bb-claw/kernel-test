#!/bin/bash
# Fetch the latest kernel tag from upstream and write the version to
# build/.kernel-version so other stages can read it without re-running git.
#
# Modes (controlled by STABLE_RELEASE env var, set by Makefile):
#   default              — fetch latest v*-rc* tag from KERNEL_TREE
#   STABLE_RELEASE=7.1   — fetch latest v7.1.* (non-rc) from KERNEL_TREE
#                          (Makefile overrides KERNEL_TREE → STABLE_KERNEL_TREE)
#
# Strategy: use git ls-remote to list matching remote refs (no objects
# transferred), pick the latest tag, then fetch only that one tag with
# --depth=1. Much faster than --tags which enumerates the entire repo.
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_env KERNEL_TREE BUILD_DIR

[[ -d $KERNEL_TREE ]]      || die "KERNEL_TREE '$KERNEL_TREE' does not exist"
[[ -d $KERNEL_TREE/.git ]] || die "'$KERNEL_TREE' is not a git repository"

if ! git -C "$KERNEL_TREE" diff --quiet 2>/dev/null; then
    warn "Kernel tree has uncommitted changes"
fi

setup_git_array

if [[ -n ${STABLE_RELEASE:-} ]]; then
    # ── Stable release mode ───────────────────────────────────────────────────

    REMOTE_URL=$(git -C "$KERNEL_TREE" remote get-url origin 2>/dev/null || true)
    if [[ "$REMOTE_URL" != *"/stable/"* && "$REMOTE_URL" != *"linux-stable"* ]]; then
        die "STABLE_RELEASE=$STABLE_RELEASE is set but origin remote '$REMOTE_URL'" \
            "does not look like a stable tree (expected URL containing '/stable/' or 'linux-stable')." \
            "Set STABLE_KERNEL_TREE to the correct path or fix the remote."
    fi
    info "Stable remote verified: $REMOTE_URL"

    # ls-remote: list matching remote refs — no objects transferred
    info "Discovering latest ${STABLE_RELEASE}.y stable tag from origin ..."
    mapfile -t _tags < <(
        "${GIT[@]}" ls-remote --tags origin "refs/tags/v${STABLE_RELEASE}.*" 2>/dev/null \
        | awk '{print $2}' | grep -v '\^{}' | sed 's|refs/tags/||' \
        | grep -v -- '-rc' | sort -V
    )
    LATEST_TAG=${_tags[-1]:-}

    if [[ -z $LATEST_TAG ]]; then
        warn "Remote tag discovery failed — checking local tags ..."
        mapfile -t _local < <(
            git -C "$KERNEL_TREE" tag -l "v${STABLE_RELEASE}.*" \
            --sort=version:refname | grep -v -- '-rc'
        )
        LATEST_TAG=${_local[-1]:-}
        [[ -n $LATEST_TAG ]] \
            || die "No stable tags found for series ${STABLE_RELEASE} locally or remotely."
        warn "Using best available local tag: $LATEST_TAG"
    else
        info "Latest ${STABLE_RELEASE}.y tag: $LATEST_TAG"
    fi

else
    # ── Mainline rc mode (default) ────────────────────────────────────────────

    # ls-remote: list matching remote refs — no objects transferred
    info "Discovering latest mainline -rc tag from origin ..."
    mapfile -t _tags < <(
        "${GIT[@]}" ls-remote --tags origin "refs/tags/v*-rc*" 2>/dev/null \
        | awk '{print $2}' | grep -v '\^{}' | sed 's|refs/tags/||' \
        | sort -V
    )
    LATEST_TAG=${_tags[-1]:-}

    if [[ -z $LATEST_TAG ]]; then
        warn "Remote tag discovery failed — checking local tags ..."
        mapfile -t _local < <(
            git -C "$KERNEL_TREE" tag -l 'v*-rc*' --sort=version:refname
        )
        LATEST_TAG=${_local[-1]:-}
        [[ -n $LATEST_TAG ]] \
            || die "No -rc tags found locally or remotely." \
                   "Ensure the kernel tree was cloned from Linus's tree and has network access."
        warn "Using best available local tag: $LATEST_TAG"
    else
        info "Latest mainline -rc tag: $LATEST_TAG"
    fi
fi

# ── Fetch only the specific tag if not already local ─────────────────────────

if git -C "$KERNEL_TREE" rev-parse --verify "${LATEST_TAG}^{commit}" &>/dev/null; then
    info "Tag $LATEST_TAG already in local history — skipping fetch"
else
    info "Fetching $LATEST_TAG ..."
    "${GIT[@]}" fetch --depth=1 origin "refs/tags/${LATEST_TAG}:refs/tags/${LATEST_TAG}" \
        || die "Failed to fetch $LATEST_TAG from origin"
fi

# ── Checkout ──────────────────────────────────────────────────────────────────

PREV_HEAD=$(git -C "$KERNEL_TREE" rev-parse --verify HEAD 2>/dev/null || true)

if ! git -C "$KERNEL_TREE" checkout "$LATEST_TAG"; then
    if [[ -n $PREV_HEAD ]]; then
        warn "Checkout failed — restoring previous working tree ..."
        git -C "$KERNEL_TREE" checkout "$PREV_HEAD" -- . 2>/dev/null || true
    fi
    die "Failed to checkout $LATEST_TAG"
fi

[[ -f "$KERNEL_TREE/Makefile" ]] || \
    die "Kernel Makefile missing after checkout of $LATEST_TAG — tree may be incomplete." \
        "Try: git -C $KERNEL_TREE checkout HEAD -- ."

mkdir -p "$BUILD_DIR"
printf '%s\n' "$LATEST_TAG" > "$BUILD_DIR/.kernel-version"
info "Version recorded in $BUILD_DIR/.kernel-version"
