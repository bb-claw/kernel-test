#!/bin/bash
# Scan a kernel subsystem for missing Kconfig 'select' dependencies.
#
# Detects two patterns:
#   1. Struct fields guarded by #ifdef CONFIG_X in subsystem headers, assigned
#      in a driver that does not 'select CONFIG_X' in its Kconfig entry.
#   2. IS_ENABLED(CONFIG_X) calls in a driver without a matching 'select'.
#
# Usage:
#   scripts/kconfig-check.sh <subsystem>
#   KERNEL_TREE=/path/to/linux VERIFY=1 scripts/kconfig-check.sh pinctrl
#   make kconfig-check SUBSYSTEM=pinctrl [VERIFY=1]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/../lib/common.sh"

SUBSYSTEM=${1:?usage: kconfig-check.sh <subsystem>}
VERIFY=${VERIFY:-0}
KERNEL_TREE=${KERNEL_TREE:-$(pwd)}

HEADER_DIR="$KERNEL_TREE/include/linux/$SUBSYSTEM"
DRIVER_DIR="$KERNEL_TREE/drivers/$SUBSYSTEM"
KCONFIG="$DRIVER_DIR/Kconfig"

[[ -d "$HEADER_DIR" ]] || die "not found: $HEADER_DIR"
[[ -d "$DRIVER_DIR" ]] || die "not found: $DRIVER_DIR"
[[ -f "$KCONFIG"    ]] || die "not found: $KCONFIG"

CANDIDATES=0

# ── Helpers ───────────────────────────────────────────────────────────────────

# pinctrl-bm1880 → PINCTRL_BM1880
config_sym() { printf '%s' "${1^^}" | tr '-' '_'; }

# True if 'config SYM' or 'menuconfig SYM' appears in the subsystem Kconfig
kconfig_has() {
    grep -qP "^(config|menuconfig) $1$" "$KCONFIG"
}

# Print the body lines of a Kconfig entry (from 'config SYM' to next entry)
kconfig_block() {
    awk -v s="$1" '
        /^(config|menuconfig) / && $2 == s { f=1; next }
        f && /^(config|menuconfig) /        { exit }
        f                                   { print }
    ' "$KCONFIG"
}

# True if a Kconfig block body ($2) contains "select $1"
block_selects() {
    printf '%s\n' "$2" | grep -qP "^\s+select\s+$1(\s|$)"
}

# Print identifier names inside all #ifdef CFG blocks in subsystem headers
guarded_identifiers() {
    local cfg=$1 h
    for h in "$HEADER_DIR"/*.h; do
        [[ -f "$h" ]] || continue
        awk -v c="$cfg" '
            /^#ifdef / && $2 == c && d == 0 { d=1; next }
            d > 0 && /^#if/                  { d++; next }
            d > 0 && /^#endif/               { d--; next }
            d > 0                            { print }
        ' "$h"
    done \
    | grep -oE '\b[a-z_][a-z0-9_]{2,}\b' \
    | grep -vxE 'bool|char|int|long|void|unsigned|signed|struct|union|enum|const|static|inline|return|typedef|true|false|size_t|u8|u16|u32|u64|s8|s16|s32|s64' \
    | sort -u
}

# Print a candidate block; optionally verify with a build
emit_candidate() {
    local cfile=$1 sym=$2 cfg=$3 evidence=$4 note=$5
    printf '[CANDIDATE] %s\n'             "$(realpath --relative-to="$KERNEL_TREE" "$cfile")"
    printf '  Kconfig entry : config %s\n' "$sym"
    printf '  Missing select: %s\n'        "$cfg"
    printf '  Evidence      : %s\n'        "$evidence"
    printf '  Note          : %s\n\n'      "$note"
    CANDIDATES=$(( CANDIDATES + 1 ))
    [[ $VERIFY -eq 1 ]] && verify_build "$sym" "$cfile" || true
}

# Build the driver object on x86_64 to confirm the candidate is a real failure
verify_build() {
    local sym=$1 cfile=$2 result tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf $tmp" RETURN

    make -C "$KERNEL_TREE" O="$tmp" ARCH=x86_64 tinyconfig >/dev/null 2>&1 || {
        warn "  VERIFY: tinyconfig failed"; return
    }
    "$KERNEL_TREE/scripts/config" --file "$tmp/.config" \
        --enable CONFIG_COMPILE_TEST --enable "CONFIG_$sym" >/dev/null 2>&1 || true
    make -C "$KERNEL_TREE" O="$tmp" ARCH=x86_64 olddefconfig >/dev/null 2>&1 || {
        warn "  VERIFY: olddefconfig failed"; return
    }
    local obj
    obj="drivers/$SUBSYSTEM/$(basename "${cfile%.c}.o")"
    if make -C "$KERNEL_TREE" O="$tmp" ARCH=x86_64 "$obj" >/dev/null 2>&1; then
        result="FALSE_POSITIVE — builds OK (symbol may be selected transitively)"
    else
        result="VERIFIED — build fails without select"
    fi
    printf '  -> [%s]\n\n' "$result"
}

# ── Pass 1: #ifdef CONFIG_X guards in subsystem headers ───────────────────────

info "kconfig-check: subsystem=$SUBSYSTEM"
info "              kernel=$KERNEL_TREE"
info "Pass 1 — #ifdef guards in include/linux/$SUBSYSTEM/"

HEADER_CFGS=()
while IFS= read -r c; do
    HEADER_CFGS+=("$c")
done < <({ grep -rh -oP '(?<=#ifdef )CONFIG_[A-Z0-9_]+' "$HEADER_DIR"/*.h 2>/dev/null || true; } | sort -u)

for cfg in "${HEADER_CFGS[@]+"${HEADER_CFGS[@]}"}"; do
    FIELDS=()
    while IFS= read -r f; do
        FIELDS+=("$f")
    done < <(guarded_identifiers "$cfg" || true)
    [[ ${#FIELDS[@]} -eq 0 ]] && continue

    # Build one combined grep pattern for all struct field assignments
    pat=$(printf '\\.%s\\s*=|' "${FIELDS[@]}")
    pat="${pat%|}"

    for cfile in "$DRIVER_DIR"/*.c; do
        [[ -f "$cfile" ]] || continue
        stem=$(basename "$cfile" .c)
        sym=$(config_sym "$stem")
        kconfig_has "$sym" || continue

        evidence=$(grep -nP "$pat" "$cfile" 2>/dev/null | head -1) || true
        [[ -z "$evidence" ]] && continue

        block=$(kconfig_block "$sym")
        block_selects "$cfg" "$block" && continue

        emit_candidate "$cfile" "$sym" "$cfg" \
            "$(basename "$cfile"):$evidence" \
            "field guarded by #ifdef $cfg in include/linux/$SUBSYSTEM/"
    done
done

# ── Pass 2: IS_ENABLED(CONFIG_X) in driver C files ───────────────────────────

info "Pass 2 — IS_ENABLED() calls in drivers/$SUBSYSTEM/"

for cfile in "$DRIVER_DIR"/*.c; do
    [[ -f "$cfile" ]] || continue
    stem=$(basename "$cfile" .c)
    sym=$(config_sym "$stem")
    kconfig_has "$sym" || continue

    block=$(kconfig_block "$sym")

    IE_CFGS=()
    while IFS= read -r c; do
        IE_CFGS+=("$c")
    done < <({ grep -oP '(?<=IS_ENABLED\()CONFIG_[A-Z0-9_]+' "$cfile" 2>/dev/null || true; } | sort -u)

    for cfg in "${IE_CFGS[@]+"${IE_CFGS[@]}"}"; do
        block_selects "$cfg" "$block" && continue
        evidence=$(grep -nP "IS_ENABLED\($cfg\)" "$cfile" 2>/dev/null | head -1) || true
        emit_candidate "$cfile" "$sym" "$cfg" \
            "$(basename "$cfile"):$evidence" \
            "IS_ENABLED($cfg) without select in Kconfig"
    done
done

# ── Summary ───────────────────────────────────────────────────────────────────

if [[ $CANDIDATES -eq 0 ]]; then
    info "No candidates found in $SUBSYSTEM"
else
    warn "$CANDIDATES candidate(s) found — run with VERIFY=1 to confirm with a build"
fi
