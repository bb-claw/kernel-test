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
#   make kconfig-check SUBSYSTEM=pinctrl [VERIFY=1] [ARCHS=arm64] [DRIVER=pinctrl-bm1880]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/../lib/common.sh"

SUBSYSTEM=${1:?usage: kconfig-check.sh <subsystem>}
VERIFY=${VERIFY:-0}
KERNEL_TREE=${KERNEL_TREE:-$(pwd)}
ARCH=${ARCH:-x86_64}
DRIVER=${DRIVER:-}

case "$ARCH" in
    arm64) CROSS_COMPILE=aarch64-linux-gnu- ;;
    *)     CROSS_COMPILE= ;;
esac

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
    local sym="${1#CONFIG_}"
    printf '%s\n' "$2" | grep -qP "^\s+select\s+$sym(\s|$)"
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
    [[ $VERIFY -eq 1 ]] && verify_build "$sym" "$cfile" "$cfg" || true
}

# Build the driver object to confirm the candidate is a real failure.
# Logs saved to build/kconfig-check-<ARCH>/<SYM>/<CFG>/ for inspection.
verify_build() {
    local sym=$1 cfile=$2 cfg=$3 result tmp
    local logdir="$REPO_ROOT/build/kconfig-check-$ARCH/$sym/${cfg#CONFIG_}"
    mkdir -p "$logdir"
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf $tmp" RETURN

    if ! make -C "$KERNEL_TREE" O="$tmp" ARCH="$ARCH" \
            ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} tinyconfig \
            >"$logdir/tinyconfig.log" 2>&1; then
        if grep -q "source tree is not clean" "$logdir/tinyconfig.log"; then
            warn "  VERIFY: kernel source tree has in-tree build artifacts"
            warn "          fix: make -C $KERNEL_TREE mrproper"
        else
            warn "  VERIFY: tinyconfig failed (see $logdir/tinyconfig.log)"
        fi
        return
    fi
    local block dep_flags=()
    block=$(kconfig_block "$sym")
    grep -qP '\bdepends on\b.*\bOF\b' <<< "$block"           && dep_flags+=(--enable CONFIG_OF)
    grep -qP '\bCOMPILE_TEST\b'       <<< "$block"           && dep_flags+=(--enable CONFIG_COMPILE_TEST)
    "$KERNEL_TREE/scripts/config" --file "$tmp/.config" \
        "${dep_flags[@]}" \
        --enable "CONFIG_$(config_sym "$SUBSYSTEM")" \
        --enable "CONFIG_$sym" >/dev/null 2>&1 || true
    if ! make -C "$KERNEL_TREE" O="$tmp" ARCH="$ARCH" \
            ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} olddefconfig \
            >"$logdir/olddefconfig.log" 2>&1; then
        warn "  VERIFY: olddefconfig failed (see $logdir/olddefconfig.log)"; return
    fi
    cp "$tmp/.config" "$logdir/.config"
    if ! grep -q "^CONFIG_${sym}=y" "$logdir/.config"; then
        local dep_line
        dep_line=$(grep -m1 'depends on' <<< "$block" | sed 's/^\s*//')
        printf '  -> [FALSE_POSITIVE — %s absent from config after olddefconfig]\n' "$sym"
        [[ -n "$dep_line" ]] && printf '     Kconfig: %s\n' "$dep_line"
        printf '     config: %s\n\n' "$logdir/.config"
        return
    fi
    local obj
    obj="drivers/$SUBSYSTEM/$(basename "${cfile%.c}.o")"
    if make -C "$KERNEL_TREE" O="$tmp" ARCH="$ARCH" \
            ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} "$obj" \
            >"$logdir/build.log" 2>&1; then
        result="FALSE_POSITIVE — builds OK (symbol may be selected transitively)"
    else
        result="VERIFIED — build fails without select"
        grep 'error:' "$logdir/build.log" | head -3 | sed 's/^/    /'
    fi
    printf '  -> [%s]\n'     "$result"
    printf '     log: %s\n' "$logdir/build.log"
    if [[ "$result" == VERIFIED* ]]; then
        local cross_line=""
        [[ -n "$CROSS_COMPILE" ]] && cross_line=" CROSS_COMPILE=$CROSS_COMPILE"
        {
            printf '#!/bin/bash\n'
            printf '# Reproducer: config %s missing '\''select %s'\''\n' "$sym" "$cfg"
            printf '# Generated by kernel-test/scripts/kconfig-check.sh\n'
            printf '# Run from the kernel source tree root.\n'
            printf 'set -x\n\n'
            printf 'make ARCH=%s%s tinyconfig\n' "$ARCH" "$cross_line"
            grep -qP '\bdepends on\b.*\bOF\b'  <<< "$block" && \
                printf 'scripts/config --enable CONFIG_OF\n'
            grep -qP '\bCOMPILE_TEST\b'         <<< "$block" && \
                printf 'scripts/config --enable CONFIG_COMPILE_TEST\n'
            printf 'scripts/config --enable CONFIG_%s\n' "$(config_sym "$SUBSYSTEM")"
            printf 'scripts/config --enable CONFIG_%s\n' "$sym"
            printf 'make ARCH=%s%s olddefconfig\n' "$ARCH" "$cross_line"
            printf '\n# Config state after olddefconfig (driver must be =y, dep must be absent):\n'
            printf 'grep "CONFIG_%s" .config\n' "$sym"
            printf 'grep "%s" .config\n' "$cfg"
            printf '\n'
            printf 'make ARCH=%s%s %s\n\n' "$ARCH" "$cross_line" "$obj"
            printf '# Expected error (build fails without '\''select %s'\'' in Kconfig):\n' "$cfg"
            grep 'error:' "$logdir/build.log" 2>/dev/null | head -3 | sed 's/^/# /'
        } > "$logdir/reproducer.sh"
        chmod +x "$logdir/reproducer.sh"
        printf '     reproducer: %s\n' "$logdir/reproducer.sh"
    fi
    printf '\n'
}

# ── Pass 1: #ifdef CONFIG_X guards in subsystem headers ───────────────────────

info "kconfig-check: subsystem=$SUBSYSTEM"
info "              kernel=$KERNEL_TREE"
info "              arch=$ARCH"
[[ -n "$DRIVER" ]] && info "              driver=$DRIVER"
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
        [[ -n "$DRIVER" && "$stem" != "$DRIVER" ]] && continue
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
    [[ -n "$DRIVER" && "$stem" != "$DRIVER" ]] && continue
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
elif [[ $VERIFY -eq 1 ]]; then
    warn "$CANDIDATES candidate(s) found"
else
    warn "$CANDIDATES candidate(s) found — run with VERIFY=1 to confirm with a build"
fi
