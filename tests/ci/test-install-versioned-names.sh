#!/bin/bash
# Tests for versioned boot filenames: kt- prefix + full version in BOOT_SUFFIX.
# Covers N1–N4.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

# Create a stable-rc kernel tree with explicit sublevel + extraversion.
# Sets and exports KERNEL_TREE.
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

# Replicate the BOOT_SUFFIX formula from lib/install.sh (without sudo/build).
make_boot_suffix() {
    printf 'kt-%s-%s-%s-%s' "$1" "$2" "$3" "$4"
}

# ── N1: BOOT_SUFFIX starts with kt- ──────────────────────────────────────────

begin_test "N1: BOOT_SUFFIX has kt- prefix for stable-rc kernel"
setup_stable_rc_tree 7 2 13 -rc2
read_kernel_makefile_version > /dev/null
suffix=$(make_boot_suffix "localconfig" "stable-rc" "$KMV_FULL" "x86_64")
assert_contains "$suffix" "kt-" "kt- prefix present"

# ── N2: BOOT_SUFFIX includes full version (sublevel + extraversion) ──────────

begin_test "N2: BOOT_SUFFIX includes sublevel and extraversion for stable-rc"
setup_stable_rc_tree 7 2 13 -rc2
read_kernel_makefile_version > /dev/null
suffix=$(make_boot_suffix "localconfig" "stable-rc" "$KMV_FULL" "x86_64")
assert_contains "$suffix" "7.2.13-rc2" "full version in suffix"
assert_not_contains "$suffix" "stable-rc-7.2-x86_64" "old short format not used"

begin_test "N2b: BOOT_SUFFIX full version for mainline rc (SUBLEVEL=0)"
setup_kernel_tree "7.3" "-rc2"
read_kernel_makefile_version > /dev/null
suffix=$(make_boot_suffix "localconfig" "mainline" "$KMV_FULL" "x86_64")
assert_contains "$suffix" "7.3.0-rc2" "full mainline rc version present"

begin_test "N2c: BOOT_SUFFIX full version for stable release (no rc)"
setup_stable_rc_tree 7 1 13 ""
read_kernel_makefile_version > /dev/null
suffix=$(make_boot_suffix "localconfig" "stable" "$KMV_FULL" "x86_64")
assert_contains "$suffix" "7.1.13" "full stable version present"
assert_not_contains "$suffix" "stable-7.1-" "short major.minor format not used"

# ── N3: GRUB glob matches new-style and old-style files ──────────────────────

begin_test "N3: GRUB glob vmlinuz-*config*-x86_64 matches new kt- files"
tmpdir; boot_dir="$_LAST_TMPDIR"
touch "$boot_dir/vmlinuz-kt-localconfig-stable-rc-7.2.13-rc2-x86_64"
touch "$boot_dir/vmlinuz-kt-tinyconfig-mainline-7.3.0-rc2-x86_64"
matches=()
for f in "$boot_dir"/vmlinuz-*config*-x86_64; do
    [ -f "$f" ] && matches+=("${f##*/}")
done
assert_contains "${matches[*]:-}" "vmlinuz-kt-localconfig-stable-rc-7.2.13-rc2-x86_64" "new localconfig matched"
assert_contains "${matches[*]:-}" "vmlinuz-kt-tinyconfig-mainline-7.3.0-rc2-x86_64"    "new tinyconfig matched"

begin_test "N3b: GRUB glob matches legacy short-named files (backward compat)"
tmpdir; boot_dir="$_LAST_TMPDIR"
touch "$boot_dir/vmlinuz-localconfig-mainline-7.2-x86_64"
touch "$boot_dir/vmlinuz-tinyconfig-stable-rc-7.2-x86_64"
matches=()
for f in "$boot_dir"/vmlinuz-*config*-x86_64; do
    [ -f "$f" ] && matches+=("${f##*/}")
done
assert_contains "${matches[*]:-}" "vmlinuz-localconfig-mainline-7.2-x86_64"  "legacy localconfig matched"
assert_contains "${matches[*]:-}" "vmlinuz-tinyconfig-stable-rc-7.2-x86_64" "legacy tinyconfig matched"

# ── N4: GRUB glob does NOT match distro kernels ───────────────────────────────

begin_test "N4: GRUB glob does not match distro-style kernels"
tmpdir; boot_dir="$_LAST_TMPDIR"
touch "$boot_dir/vmlinuz-6.12-x86_64"
touch "$boot_dir/vmlinuz-7.1-x86_64"
touch "$boot_dir/vmlinuz-6.1-x86_64"
matched=false
for f in "$boot_dir"/vmlinuz-*config*-x86_64; do
    [ -f "$f" ] && matched=true && break
done
if [[ $matched == false ]]; then
    pass "distro kernels not matched by GRUB glob"
else
    fail "distro kernel matched — would create spurious GRUB entry"
fi

# ── Source-level checks: verify install.sh was updated correctly ──────────────

begin_test "install.sh: GRUB heredoc uses vmlinuz-*config*-x86_64 glob"
glob_line=$(grep 'for vmlinuz in.*vmlinuz-.*x86_64' "$REPO/lib/install.sh" || true)
assert_contains "$glob_line" '*config*' "glob contains *config* wildcard"
assert_not_contains "$glob_line" 'vmlinuz-localconfig-*-x86_64' "old hardcoded localconfig glob removed"

begin_test "install.sh: BOOT_SUFFIX assignment uses kt- prefix"
suffix_line=$(grep 'BOOT_SUFFIX=' "$REPO/lib/install.sh" | grep -v '#' | tail -1)
assert_contains "$suffix_line" 'kt-' "kt- prefix in BOOT_SUFFIX"

begin_test "install.sh: BOOT_SUFFIX uses KERNEL_FULL_VERSION not MAJOR_MINOR"
suffix_line=$(grep 'BOOT_SUFFIX=' "$REPO/lib/install.sh" | grep -v '#' | tail -1)
assert_contains     "$suffix_line" 'KERNEL_FULL_VERSION' "KERNEL_FULL_VERSION used"
assert_not_contains "$suffix_line" 'MAJOR_MINOR'         "MAJOR_MINOR not used in suffix"

finish
