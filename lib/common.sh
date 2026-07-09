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

# Usage: is_build_only <config>
# Returns 0 if config is in BUILD_ONLY_CONFIGS, 1 otherwise.
is_build_only() {
    local cfg="$1" bc
    for bc in ${BUILD_ONLY_CONFIGS:-}; do
        [[ $cfg == "$bc" ]] && return 0
    done
    return 1
}
