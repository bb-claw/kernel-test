#!/bin/bash
# Fetch and checkout a specific tag or commit in KERNEL_TREE.
# Usage: checkout.sh <tag-or-commit>
# Writes build/.kernel-version; touches KERNEL_TREE/Makefile so Make
# detects stale build artifacts after a version switch.
set -euo pipefail
. "$(dirname "$0")/common.sh"

REF=${1:?usage: checkout.sh <tag-or-commit>}

require_env KERNEL_TREE BUILD_DIR

[[ -d $KERNEL_TREE ]]      || die "KERNEL_TREE '$KERNEL_TREE' does not exist"
[[ -d $KERNEL_TREE/.git ]] || die "'$KERNEL_TREE' is not a git repository"

GIT=( git -C "$KERNEL_TREE" -c http.lowSpeedLimit=0 -c http.lowSpeedTime=0 )

# ── Ensure the ref is available locally ───────────────────────────────────────

if ! git -C "$KERNEL_TREE" rev-parse --verify "${REF}^{commit}" &>/dev/null; then
    info "Ref '$REF' not in local history — fetching from origin ..."
    # Try as a tag refspec first, then as a bare ref
    "${GIT[@]}" fetch --depth=1 origin "refs/tags/${REF}:refs/tags/${REF}" 2>/dev/null \
        || "${GIT[@]}" fetch --depth=1 origin "$REF" \
        || die "Could not fetch '$REF' from origin — check spelling and network access"
fi

# ── Checkout ──────────────────────────────────────────────────────────────────

PREV_HEAD=$(git -C "$KERNEL_TREE" rev-parse HEAD 2>/dev/null || true)

info "Checking out $REF ..."
if ! git -C "$KERNEL_TREE" checkout "$REF"; then
    if [[ -n $PREV_HEAD ]]; then
        warn "Checkout failed — restoring previous HEAD ..."
        git -C "$KERNEL_TREE" checkout "$PREV_HEAD" -- . 2>/dev/null || true
    fi
    die "Failed to checkout $REF"
fi

[[ -f "$KERNEL_TREE/Makefile" ]] || \
    die "Kernel Makefile missing after checkout — try: git -C $KERNEL_TREE checkout HEAD -- ."

# Touch the kernel Makefile so Make's file-dependency rules treat all existing
# build.status files as stale after a kernel version switch.
touch "$KERNEL_TREE/Makefile"

# ── Record version ────────────────────────────────────────────────────────────

# Prefer an exact tag label; fall back to short commit hash.
VERSION=$(git -C "$KERNEL_TREE" describe --exact-match HEAD 2>/dev/null \
    || git -C "$KERNEL_TREE" rev-parse --short HEAD)

mkdir -p "$BUILD_DIR"
printf '%s\n' "$VERSION" > "$BUILD_DIR/.kernel-version"
info "Checked out: $VERSION  ($(git -C "$KERNEL_TREE" rev-parse --short HEAD))"
info "Version recorded in $BUILD_DIR/.kernel-version"

# ── Verify kernel Makefile agrees with the checked-out version ────────────────

KMV_TAG=''; KMV_FULL=''
# Call without $() so the variables it sets are visible in this shell.
if read_kernel_makefile_version >/dev/null; then
    info "Kernel Makefile: $KMV_FULL"
    # Only compare when REF looks like a tag (starts with v); commit hashes won't match.
    if [[ $REF == v* && $KMV_TAG != "$REF" ]]; then
        warn "Version mismatch: requested '$REF' but kernel Makefile says '$KMV_TAG'"
    else
        info "Makefile version matches: $KMV_TAG"
    fi
else
    warn "Could not read version from $KERNEL_TREE/Makefile"
fi
