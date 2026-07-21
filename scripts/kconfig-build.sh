#!/bin/bash
# Build a full kernel image for a specific driver to confirm a Kconfig fix.
#
# Complements kconfig-check VERIFY=1 (which builds only the driver object):
# this builds the complete kernel image, confirming the fix is end-to-end clean.
#
# Usage:
#   scripts/kconfig-build.sh <subsystem>
#   make kconfig-build SUBSYSTEM=pinctrl DRIVER=pinctrl-bm1880 [ARCHS=arm64]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/../lib/common.sh"

SUBSYSTEM=${1:?usage: kconfig-build.sh <subsystem>}
DRIVER=${DRIVER:?usage: make kconfig-build SUBSYSTEM=<name> DRIVER=<stem>}
DRIVER=${DRIVER%.c}
KERNEL_TREE=${KERNEL_TREE:-$(pwd)}
ARCH=${ARCH:-x86_64}
GATE_CFGS=${GATE_CFGS:-}

case "$ARCH" in
    arm64) CROSS_COMPILE=aarch64-linux-gnu-; IMAGE=Image   ;;
    i386)  CROSS_COMPILE=;                   IMAGE=bzImage ;;
    *)     CROSS_COMPILE=;                   IMAGE=bzImage ;;
esac

DRIVER_DIR="$KERNEL_TREE/drivers/$SUBSYSTEM"
KCONFIG="$DRIVER_DIR/Kconfig"

[[ -d "$DRIVER_DIR" ]] || die "not found: $DRIVER_DIR"
[[ -f "$KCONFIG"    ]] || die "not found: $KCONFIG"

# ── Helpers (duplicated from kconfig-check.sh) ────────────────────────────────

config_sym() { printf '%s' "${1^^}" | tr '-' '_'; }

kconfig_block() {
    awk -v s="$1" '
        /^(config|menuconfig) / && $2 == s { f=1; next }
        f && /^(config|menuconfig) /        { exit }
        f                                   { print }
    ' "$KCONFIG"
}

# ── Main ──────────────────────────────────────────────────────────────────────

SYM=$(config_sym "$DRIVER")
LOGDIR="$REPO_ROOT/build/kconfig-build-$ARCH/$SYM"
mkdir -p "$LOGDIR"

info "kconfig-build: subsystem=$SUBSYSTEM"
info "              driver=$DRIVER ($SYM)"
info "              kernel=$KERNEL_TREE"
info "              arch=$ARCH"
info "              image=$IMAGE"
info "              logdir=$LOGDIR"
[[ -n "$GATE_CFGS" ]] && info "              gate=$GATE_CFGS"

BLOCK=$(kconfig_block "$SYM")
if [[ -z "$BLOCK" ]]; then
    die "config $SYM not found in $KCONFIG"
fi

# Build dep enables from driver's depends on
DEP_FLAGS=()
grep -qP '\bdepends on\b.*\bOF\b' <<< "$BLOCK"  && DEP_FLAGS+=(--enable CONFIG_OF)
grep -qP '\bCOMPILE_TEST\b'       <<< "$BLOCK"  && DEP_FLAGS+=(--enable CONFIG_COMPILE_TEST)
GATE_CFGS_ARRAY=()
if [[ -n "$GATE_CFGS" ]]; then
    IFS=',' read -ra GATE_CFGS_ARRAY <<< "$GATE_CFGS"
fi
for sc in "${GATE_CFGS_ARRAY[@]+"${GATE_CFGS_ARRAY[@]}"}"; do
    DEP_FLAGS+=(--enable "$sc")
done

TMP=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf $TMP" EXIT

# ── Step 1: tinyconfig ────────────────────────────────────────────────────────

info "Step 1/4: tinyconfig"
if ! make -C "$KERNEL_TREE" O="$TMP" ARCH="$ARCH" \
        ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} tinyconfig \
        >"$LOGDIR/tinyconfig.log" 2>&1; then
    if grep -q "source tree is not clean" "$LOGDIR/tinyconfig.log"; then
        die "kernel source tree has in-tree build artifacts — run: make -C $KERNEL_TREE mrproper"
    fi
    die "tinyconfig failed (see $LOGDIR/tinyconfig.log)"
fi

# ── Step 2: enable driver + deps, olddefconfig ────────────────────────────────

info "Step 2/4: enabling CONFIG_$(config_sym "$SUBSYSTEM"), CONFIG_$SYM${DEP_FLAGS[*]:+ + dep flags}"
"$KERNEL_TREE/scripts/config" --file "$TMP/.config" \
    "${DEP_FLAGS[@]}" \
    --enable "CONFIG_$(config_sym "$SUBSYSTEM")" \
    --enable "CONFIG_$SYM" >/dev/null 2>&1 || true

info "Step 3/4: olddefconfig"
if ! make -C "$KERNEL_TREE" O="$TMP" ARCH="$ARCH" \
        ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} olddefconfig \
        >"$LOGDIR/olddefconfig.log" 2>&1; then
    die "olddefconfig failed (see $LOGDIR/olddefconfig.log)"
fi
cp "$TMP/.config" "$LOGDIR/.config"

if ! grep -q "^CONFIG_${SYM}=y" "$LOGDIR/.config"; then
    DEP_LINE=$(grep -m1 'depends on' <<< "$BLOCK" | sed 's/^\s*//')
    warn "CONFIG_$SYM absent from .config after olddefconfig — driver dropped"
    [[ -n "$DEP_LINE" ]] && warn "Kconfig: $DEP_LINE"
    warn "config: $LOGDIR/.config"
    exit 1
fi

# ── Step 3: full kernel build ─────────────────────────────────────────────────

info "Step 4/4: building $IMAGE (this may take several minutes)"
START=$(date +%s)
if make -C "$KERNEL_TREE" O="$TMP" ARCH="$ARCH" \
        ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} \
        "$IMAGE" >"$LOGDIR/build.log" 2>&1; then
    ELAPSED=$(( $(date +%s) - START ))
    info "PASS — $IMAGE built in ${ELAPSED}s"
    info "log: $LOGDIR/build.log"
else
    ELAPSED=$(( $(date +%s) - START ))
    warn "FAIL — build failed after ${ELAPSED}s"
    grep 'error:' "$LOGDIR/build.log" | head -5 | sed 's/^/  /'
    warn "log: $LOGDIR/build.log"
    exit 1
fi
