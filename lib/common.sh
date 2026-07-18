#!/bin/bash
# Sourced by all lib scripts — not invoked directly.

# Colour support: only when stdout is a terminal
if [[ -t 1 ]] && command -v tput &>/dev/null; then
    _GRN=$(tput setaf 2); _RED=$(tput setaf 1); _YLW=$(tput setaf 3); _RST=$(tput sgr0)
else
    _GRN=''; _RED=''; _YLW=''; _RST=''
fi

log()  { printf '%s %s\n'          "$(date -u +%H:%M:%S)" "$*"; }
info() { log "${_GRN}INFO${_RST}  $*"; }
warn() { log "${_YLW}WARN${_RST}  $*" >&2; }
die()  { log "${_RED}ERROR${_RST} $*" >&2; exit 1; }

# Usage: require_env VAR [VAR ...]
# Abort if any listed variable is unset or empty.
require_env() {
    local var
    for var in "$@"; do
        [[ -v $var && -n ${!var} ]] || die "Required variable \$$var is not set"
    done
}

# Parse VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION from KERNEL_TREE/Makefile.
# Sets KMV_TAG (e.g. v7.2-rc2) and KMV_FULL (e.g. 7.2.0-rc2).
# Echos KMV_TAG; returns 1 if the file is not readable.
read_kernel_makefile_version() {
    local mf="${KERNEL_TREE}/Makefile"
    [[ -f $mf ]] || return 1
    local _ver _pl _sl _ev
    _ver=$(grep -m1 '^VERSION[[:space:]]*='      "$mf" | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')
    _pl=$( grep -m1 '^PATCHLEVEL[[:space:]]*='   "$mf" | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')
    _sl=$( grep -m1 '^SUBLEVEL[[:space:]]*='     "$mf" | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')
    _ev=$( grep -m1 '^EXTRAVERSION[[:space:]]*=' "$mf" | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')
    # shellcheck disable=SC2034  # read by caller (checkout.sh) after sourcing common.sh
    KMV_FULL="${_ver}.${_pl}.${_sl}${_ev}"
    if [[ ${_sl:-0} -eq 0 && $_ev == -rc* ]]; then
        KMV_TAG="v${_ver}.${_pl}${_ev}"
    elif [[ ${_sl:-0} -gt 0 ]]; then
        KMV_TAG="v${_ver}.${_pl}.${_sl}${_ev}"
    else
        KMV_TAG="v${_ver}.${_pl}${_ev}"
    fi
    echo "$KMV_TAG"
}

# Shared fetch helpers — used by lib/fetch*.sh scripts.

# Set GIT array for git operations on KERNEL_TREE with timeout config.
setup_git_array() {
    GIT=( git -C "$KERNEL_TREE" -c http.lowSpeedLimit=0 -c http.lowSpeedTime=0 )
}

# git reset --hard FETCH_HEAD; die on failure. Requires setup_git_array first.
reset_to_fetch_head() {
    info "Resetting HEAD to FETCH_HEAD ..."
    "${GIT[@]}" reset --hard FETCH_HEAD \
        || die "Failed to reset to FETCH_HEAD"
}

# Read version from kernel Makefile; write to build/.kernel-version.
# Sets KERNEL_VERSION in the caller's scope.
write_kernel_version() {
    KERNEL_VERSION=$(read_kernel_makefile_version) \
        || die "Could not read version from $KERNEL_TREE/Makefile"
    mkdir -p "$BUILD_DIR"
    printf '%s\n' "$KERNEL_VERSION" > "$BUILD_DIR/.kernel-version"
}

# Usage: is_build_only <config>
# Returns 0 if config is in BUILD_ONLY_CONFIGS, 1 otherwise.
is_build_only() {
    local cfg="$1" bc
    for bc in ${BUILD_ONLY_CONFIGS:-}; do
        [[ $cfg == "$bc" ]] && return 0
    done
    return 1
}
