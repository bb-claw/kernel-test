#!/bin/bash
# Enumerate all config/menuconfig entries from a subsystem Kconfig file.
# Recursively follows 'source' directives; skips paths with variable references.
#
# Usage:
#   scripts/kconfig-enumerate.sh <subsystem>
#   KERNEL_TREE=/path/to/linux scripts/kconfig-enumerate.sh pinctrl
# Output:
#   CONFIG_PINCTRL_AT91
#   CONFIG_PINCTRL_BCM2835
#   ...  (one CONFIG_NAME per line, sorted, deduplicated)
set -euo pipefail

SUBSYSTEM=${1:?usage: kconfig-enumerate.sh <subsystem>}
KERNEL_TREE=${KERNEL_TREE:-$(pwd)}

DRIVER_DIR="$KERNEL_TREE/drivers/$SUBSYSTEM"
ROOT_KCONFIG="$DRIVER_DIR/Kconfig"

[[ -d "$DRIVER_DIR" ]] || { printf 'ERROR: not found: %s\n' "$DRIVER_DIR" >&2; exit 1; }
[[ -f "$ROOT_KCONFIG" ]] || { printf 'ERROR: not found: %s\n' "$ROOT_KCONFIG" >&2; exit 1; }

# Emit config symbols from a single Kconfig file, then recurse into sourced files.
# Visited set prevents infinite loops from circular sources.
declare -A _VISITED

enumerate_kconfig() {
    local kfile=$1
    local real
    real=$(realpath "$kfile" 2>/dev/null) || return 0
    [[ -v _VISITED[$real] ]] && return 0
    _VISITED[$real]=1

    local line sym path
    while IFS= read -r line; do
        case "$line" in
            config\ *|menuconfig\ *)
                sym=${line#* }
                sym=${sym%%[[:space:]]*}
                printf 'CONFIG_%s\n' "$sym"
                ;;
            source\ *)
                path=${line#source }
                path=${path#\"}
                path=${path%\"}
                # Skip paths with Kconfig variable references (e.g. $(SRCARCH))
                [[ "$path" == *\$* ]] && continue
                path="$KERNEL_TREE/$path"
                [[ -f "$path" ]] && enumerate_kconfig "$path"
                ;;
        esac
    done < "$kfile"
}

enumerate_kconfig "$ROOT_KCONFIG" | sort -u
