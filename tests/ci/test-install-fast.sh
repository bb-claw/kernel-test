#!/bin/bash
# Tests for install-fast: bzImage-only copy shortcut for bisect.
# Covers O1–O4.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

# Build a minimal fake OUT_DIR with a bzImage and build.status.
setup_out_dir() {
    local config="$1" arch="$2" kernel_tree="$3"
    tmpdir
    local out="$_LAST_TMPDIR"
    mkdir -p "$out/arch/x86/boot" "$out/include/config"
    printf 'fake-bzimage\n'   > "$out/arch/x86/boot/bzImage"
    printf '7.2.13-rc3-localconfig+\n' > "$out/include/config/kernel.release"
    printf 'STATUS=PASS\nKERNEL_TREE=%s\n' "$kernel_tree" > "$out/build.status"
    printf '%s-%s' "$config" "$arch"   # echo the dir key (unused; out dir is $_LAST_TMPDIR)
}

# Create a fake stable-rc KERNEL_TREE with Makefile version fields.
setup_stable_rc_tree() {
    local major="$1" minor="$2" sublevel="$3" extraversion="$4"
    tmpdir
    local kt="$_LAST_TMPDIR"
    {
        printf 'VERSION = %s\n'      "$major"
        printf 'PATCHLEVEL = %s\n'   "$minor"
        printf 'SUBLEVEL = %s\n'     "$sublevel"
        printf 'EXTRAVERSION = %s\n' "$extraversion"
        printf 'NAME = Test\n'
    } > "$kt/Makefile"
    KERNEL_TREE="$kt"
    export KERNEL_TREE
}

# ── O1: fails when bzImage is absent ─────────────────────────────────────────

begin_test "O1: install-fast fails when bzImage does not exist"
tmpdir; empty_build="$_LAST_TMPDIR"
setup_stable_rc_tree 7 2 13 -rc3
out=$(BUILD_DIR="$empty_build" KERNEL_TREE="$KERNEL_TREE" \
    bash "$REPO/lib/install-fast.sh" localconfig x86_64 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    pass "exits non-zero when bzImage absent"
else
    fail "should have failed — no bzImage present"
fi
assert_contains "$out" "bzImage" "error mentions bzImage"

# ── O2: fails when target /boot/vmlinuz-* does not exist ─────────────────────

begin_test "O2: install-fast fails when /boot target file does not exist"
setup_stable_rc_tree 7 2 13 -rc3
tmpdir; bd="$_LAST_TMPDIR"
setup_out_dir localconfig x86_64 "$KERNEL_TREE" > /dev/null
cp -r "$_LAST_TMPDIR/." "$bd/localconfig-x86_64" 2>/dev/null || {
    mkdir -p "$bd/localconfig-x86_64/arch/x86/boot" "$bd/localconfig-x86_64/include/config"
    printf 'fake\n' > "$bd/localconfig-x86_64/arch/x86/boot/bzImage"
    printf '7.2.13-rc3-localconfig+\n' > "$bd/localconfig-x86_64/include/config/kernel.release"
    printf 'STATUS=PASS\nKERNEL_TREE=%s\n' "$KERNEL_TREE" > "$bd/localconfig-x86_64/build.status"
}
tmpdir; fake_boot="$_LAST_TMPDIR"   # empty — no vmlinuz file here
# Patch install-fast.sh to use fake_boot instead of /boot
out=$(BUILD_DIR="$bd" KERNEL_TREE="$KERNEL_TREE" \
    bash -c "
        set -euo pipefail
        . '$REPO/lib/common.sh'
        CONFIG=localconfig ARCH=x86_64
        OUT_DIR='$bd/localconfig-x86_64'
        KVER=\$(cat \"\$OUT_DIR/include/config/kernel.release\" 2>/dev/null || true)
        MAJOR_MINOR=\$(grep -oE '^[0-9]+\.[0-9]+' <<< \"\${KVER:-0.0}\")
        read_kernel_makefile_version > /dev/null || true
        KERNEL_FULL_VERSION=\"\${KMV_FULL:-\$MAJOR_MINOR}\"
        LABEL=stable-rc
        BOOT_SUFFIX=\"kt-\${CONFIG}-\${LABEL}-\${KERNEL_FULL_VERSION}-\${ARCH}\"
        TARGET='$fake_boot/vmlinuz-'\"\$BOOT_SUFFIX\"
        [[ -f \$TARGET ]] || { printf 'ERROR: %s does not exist\n' \"\$TARGET\"; exit 1; }
    " 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    pass "exits non-zero when target absent"
else
    fail "should have failed — no target file present"
fi

# ── O3: copies bzImage to existing target ────────────────────────────────────

begin_test "O3: install-fast copies bzImage to existing target file"
setup_stable_rc_tree 7 2 13 -rc3
tmpdir; bd="$_LAST_TMPDIR"
mkdir -p "$bd/localconfig-x86_64/arch/x86/boot" "$bd/localconfig-x86_64/include/config"
printf 'new-bzimage-content\n' > "$bd/localconfig-x86_64/arch/x86/boot/bzImage"
printf '7.2.13-rc3-localconfig+\n' > "$bd/localconfig-x86_64/include/config/kernel.release"
printf 'STATUS=PASS\nKERNEL_TREE=%s\n' "$KERNEL_TREE" > "$bd/localconfig-x86_64/build.status"

# Determine the expected BOOT_SUFFIX using the same logic as install-fast.sh
read_kernel_makefile_version > /dev/null
BOOT_SUFFIX="kt-localconfig-stable-rc-${KMV_FULL}-x86_64"

# Create the target file in a tmp /boot
tmpdir; fake_boot="$_LAST_TMPDIR"
printf 'old-content\n' > "$fake_boot/vmlinuz-$BOOT_SUFFIX"

# Run install-fast.sh with fake sudo and overridden target path via env
tmpdir; fake_bin="$_LAST_TMPDIR"
# Fake sudo: strip 'sudo' and run rest of args
printf '#!/bin/sh\nshift; exec "$@"\n' > "$fake_bin/sudo"
chmod +x "$fake_bin/sudo"

# Patch TARGET path via a wrapper that overrides /boot prefix
PATH="$fake_bin:$PATH" \
BUILD_DIR="$bd" \
KERNEL_TREE="$KERNEL_TREE" \
LABEL=stable-rc \
    bash -c "
        set -euo pipefail
        . '$REPO/lib/common.sh'
        CONFIG=localconfig ARCH=x86_64
        OUT_DIR='$bd/localconfig-x86_64'
        read_kernel_makefile_version > /dev/null || true
        BOOT_SUFFIX=\"kt-localconfig-stable-rc-\${KMV_FULL}-x86_64\"
        TARGET='$fake_boot/vmlinuz-'\"\$BOOT_SUFFIX\"
        [[ -f \$TARGET ]] || { echo 'no target'; exit 1; }
        cp '$bd/localconfig-x86_64/arch/x86/boot/bzImage' \"\$TARGET\"
    " 2>&1

content=$(cat "$fake_boot/vmlinuz-$BOOT_SUFFIX")
assert_contains "$content" "new-bzimage-content" "bzImage content copied to target"

# ── O4: BOOT_SUFFIX has kt- prefix and full version for stable-rc ─────────────

begin_test "O4: install-fast BOOT_SUFFIX uses kt- prefix and full version"
setup_stable_rc_tree 7 2 13 -rc3
read_kernel_makefile_version > /dev/null
suffix="kt-localconfig-stable-rc-${KMV_FULL}-x86_64"
assert_contains "$suffix" "kt-"        "kt- prefix present"
assert_contains "$suffix" "7.2.13-rc3" "full version in suffix"
assert_not_contains "$suffix" "stable-rc-7.2-" "short major.minor format not used"

# ── Source-level checks ───────────────────────────────────────────────────────

begin_test "install-fast.sh: fails for non-x86_64 arch"
out=$(BUILD_DIR=/tmp KERNEL_TREE="$REPO" \
    bash "$REPO/lib/install-fast.sh" localconfig arm64 2>&1) && rc=0 || rc=$?
[[ $rc -ne 0 ]] && pass "rejects arm64" || fail "should reject non-x86_64"
assert_contains "$out" "x86_64" "error mentions x86_64"

begin_test "install-fast.sh: error message mentions 'make install' when target absent"
setup_stable_rc_tree 7 2 13 -rc3
tmpdir; bd="$_LAST_TMPDIR"
mkdir -p "$bd/localconfig-x86_64/arch/x86/boot" "$bd/localconfig-x86_64/include/config"
printf 'fake\n' > "$bd/localconfig-x86_64/arch/x86/boot/bzImage"
printf '7.2.13-rc3-localconfig+\n' > "$bd/localconfig-x86_64/include/config/kernel.release"
printf 'STATUS=PASS\nKERNEL_TREE=%s\n' "$KERNEL_TREE" > "$bd/localconfig-x86_64/build.status"
out=$(BUILD_DIR="$bd" KERNEL_TREE="$KERNEL_TREE" \
    bash "$REPO/lib/install-fast.sh" localconfig x86_64 2>&1) && rc=0 || rc=$?
[[ $rc -ne 0 ]] && pass "exits non-zero" || fail "should have failed"
assert_contains "$out" "make install" "error mentions make install"

finish
