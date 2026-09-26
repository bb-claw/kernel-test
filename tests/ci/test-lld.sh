#!/bin/bash
# CI tests for LLD auto-detect: detect_lld() unit tests, preflight output, report LINKER field.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/tests/ci/lib.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

make_base_dir() {
    local d
    d=$(mktemp -d)
    for t in df awk mkdir env printf dirname date bash sort head grep cut; do
        ln -sf "$(command -v "$t")" "$d/$t"
    done
    echo "$d"
}

add_lld_stub() {
    local bd="$1" ver="$2"
    printf '#!/bin/bash\necho "LLD %s (compatible with GNU linkers)"\n' "$ver" > "$bd/ld.lld"
    chmod +x "$bd/ld.lld"
}

add_min_version_stub() {
    local kdir="$1" ver="$2"
    printf '#!/bin/bash\necho "%s"\n' "$ver" > "$kdir/scripts/min-tool-version.sh"
    chmod +x "$kdir/scripts/min-tool-version.sh"
}

run_detect_lld() {
    # Run detect_lld() in a subshell with controlled PATH and KERNEL_TREE.
    # Prints "ok VER MIN" on success, "fail VER MIN" on failure.
    local bd="$1" kdir="${2:-}"
    (
        PATH="$bd"
        USE_LLD="${USE_LLD:-1}"
        # shellcheck disable=SC2034  # KERNEL_TREE is read by detect_lld() from sourced common.sh
        KERNEL_TREE="$kdir"
        . "$REPO/lib/common.sh"
        if detect_lld; then
            echo "ok $LLD_VERSION $LLD_MIN"
        else
            echo "fail $LLD_VERSION $LLD_MIN"
        fi
    )
}

# ── detect_lld() unit tests ───────────────────────────────────────────────────
begin_test "detect_lld: good LLD version"
bd=$(make_base_dir)
add_lld_stub "$bd" "22.1.8"
kdir=$(mktemp -d) && mkdir -p "$kdir/scripts"
add_min_version_stub "$kdir" "17.0.1"
result=$(run_detect_lld "$bd" "$kdir")
[[ "$result" == "ok 22.1.8 17.0.1" ]] \
    && pass "returns 0, sets LLD_VERSION=22.1.8 LLD_MIN=17.0.1" \
    || fail "expected 'ok 22.1.8 17.0.1', got '$result'"
rm -rf "$bd" "$kdir"

begin_test "detect_lld: LLD version too old"
bd=$(make_base_dir)
add_lld_stub "$bd" "14.0.6"
kdir=$(mktemp -d) && mkdir -p "$kdir/scripts"
add_min_version_stub "$kdir" "17.0.1"
result=$(run_detect_lld "$bd" "$kdir")
[[ "$result" == "fail 14.0.6 17.0.1" ]] \
    && pass "returns 1, sets LLD_VERSION=14.0.6 (below min)" \
    || fail "expected 'fail 14.0.6 17.0.1', got '$result'"
rm -rf "$bd" "$kdir"

begin_test "detect_lld: ld.lld absent"
bd=$(make_base_dir)
result=$(run_detect_lld "$bd" "")
[[ "$result" == "fail  17.0.1" ]] \
    && pass "returns 1, LLD_VERSION empty" \
    || fail "expected 'fail  17.0.1', got '$result'"
rm -rf "$bd"

begin_test "detect_lld: USE_LLD=0 disables"
bd=$(make_base_dir)
add_lld_stub "$bd" "22.1.8"
result=$(USE_LLD=0 run_detect_lld "$bd" "")
[[ "$result" == "fail  17.0.1" ]] \
    && pass "returns 1 immediately when USE_LLD=0" \
    || fail "expected 'fail  17.0.1', got '$result'"
rm -rf "$bd"

begin_test "detect_lld: reads min from kernel scripts/min-tool-version.sh"
bd=$(make_base_dir)
add_lld_stub "$bd" "19.0.0"
kdir=$(mktemp -d) && mkdir -p "$kdir/scripts"
add_min_version_stub "$kdir" "18.0.0"
result=$(run_detect_lld "$bd" "$kdir")
[[ "$result" == "ok 19.0.0 18.0.0" ]] \
    && pass "uses 18.0.0 from kernel min-tool-version.sh (not hardcoded 17.0.1)" \
    || fail "expected 'ok 19.0.0 18.0.0', got '$result'"
rm -rf "$bd" "$kdir"

begin_test "detect_lld: falls back to 17.0.1 without kernel tree"
bd=$(make_base_dir)
add_lld_stub "$bd" "22.1.8"
result=$(run_detect_lld "$bd" "")
[[ "$result" == "ok 22.1.8 17.0.1" ]] \
    && pass "uses hardcoded 17.0.1 fallback when KERNEL_TREE has no min-tool-version.sh" \
    || fail "expected 'ok 22.1.8 17.0.1', got '$result'"
rm -rf "$bd"

# ── preflight output ──────────────────────────────────────────────────────────
begin_test "preflight: prints LLD version when LLD available"
bd=$(make_base_dir)
add_lld_stub "$bd" "22.1.8"
kdir=$(mktemp -d) && mkdir -p "$kdir/scripts"
add_min_version_stub "$kdir" "17.0.1"
mkdir -p "$bd/../build" "$bd/../cache"
out=$(PATH="$bd" GCC=bash USE_LLD=1 KERNEL_TREE="$kdir" ARCHS=x86_64 \
    BUILD_DIR="$bd/../build" CACHE_DIR="$bd/../cache" \
    bash "$REPO/lib/preflight.sh" 2>&1 || true)
echo "$out" | grep -q "LLD 22.1.8.*using ld.lld" \
    && pass "output contains 'LLD 22.1.8 ... using ld.lld'" \
    || fail "expected LLD info in output, got: $out"
rm -rf "$bd" "$kdir"

begin_test "preflight: prints version mismatch when LLD too old"
bd=$(make_base_dir)
add_lld_stub "$bd" "14.0.6"
kdir=$(mktemp -d) && mkdir -p "$kdir/scripts"
add_min_version_stub "$kdir" "17.0.1"
mkdir -p "$bd/../build" "$bd/../cache"
out=$(PATH="$bd" GCC=bash USE_LLD=1 KERNEL_TREE="$kdir" ARCHS=x86_64 \
    BUILD_DIR="$bd/../build" CACHE_DIR="$bd/../cache" \
    bash "$REPO/lib/preflight.sh" 2>&1 || true)
echo "$out" | grep -qE "14\.0\.6.*<.*17\.0\.1|below|BFD" \
    && pass "output contains version mismatch warning" \
    || fail "expected version mismatch in output, got: $out"
rm -rf "$bd" "$kdir"

begin_test "preflight: prints 'not found' when LLD absent"
bd=$(make_base_dir)
mkdir -p "$bd/../build" "$bd/../cache"
out=$(PATH="$bd" GCC=bash USE_LLD=1 KERNEL_TREE="" ARCHS=x86_64 \
    BUILD_DIR="$bd/../build" CACHE_DIR="$bd/../cache" \
    bash "$REPO/lib/preflight.sh" 2>&1 || true)
echo "$out" | grep -qE "not found|BFD" \
    && pass "output contains 'not found — using BFD'" \
    || fail "expected 'not found' in output, got: $out"
rm -rf "$bd"

# ── LINKER detection in report.sh (detection logic unit test) ─────────────────
begin_test "report: detects LINKER=lld from build.status"
tmp=$(mktemp -d)
mkdir -p "$tmp/build/defconfig-x86_64"
printf 'STATUS=PASS\nLINKER=lld\n' > "$tmp/build/defconfig-x86_64/build.status"
# Replicate the LINKER_USED scan from report.sh
LINKER_USED=bfd
for _bs in "$tmp/build"/*-*/build.status; do
    [[ -f "$_bs" ]] || continue
    _l=$(grep "^LINKER=" "$_bs" 2>/dev/null | cut -d= -f2 || true)
    if [[ -n "$_l" ]]; then LINKER_USED="$_l"; break; fi
done
[[ "$LINKER_USED" == "lld" ]] \
    && pass "LINKER_USED=lld when build.status has LINKER=lld" \
    || fail "expected lld, got '$LINKER_USED'"
rm -rf "$tmp"

# ── llvm-objcopy detection (preflight output) ────────────────────────────────
begin_test "preflight: no objcopy warning when llvm-objcopy present"
bd=$(make_base_dir)
add_lld_stub "$bd" "22.1.8"
printf '#!/bin/bash\n' > "$bd/llvm-objcopy" && chmod +x "$bd/llvm-objcopy"
kdir=$(mktemp -d) && mkdir -p "$kdir/scripts"
add_min_version_stub "$kdir" "17.0.1"
mkdir -p "$bd/../build" "$bd/../cache"
out=$(PATH="$bd" GCC=bash USE_LLD=1 KERNEL_TREE="$kdir" ARCHS=x86_64 \
    BUILD_DIR="$bd/../build" CACHE_DIR="$bd/../cache" \
    bash "$REPO/lib/preflight.sh" 2>&1 || true)
echo "$out" | grep -q "llvm-objcopy not found" \
    && fail "unexpected objcopy warning in output: $out" \
    || pass "no objcopy warning when llvm-objcopy is present"
rm -rf "$bd" "$kdir"

begin_test "preflight: objcopy warning when llvm-objcopy absent"
bd=$(make_base_dir)
add_lld_stub "$bd" "22.1.8"
kdir=$(mktemp -d) && mkdir -p "$kdir/scripts"
add_min_version_stub "$kdir" "17.0.1"
mkdir -p "$bd/../build" "$bd/../cache"
out=$(PATH="$bd" GCC=bash USE_LLD=1 KERNEL_TREE="$kdir" ARCHS=x86_64 \
    BUILD_DIR="$bd/../build" CACHE_DIR="$bd/../cache" \
    bash "$REPO/lib/preflight.sh" 2>&1 || true)
echo "$out" | grep -q "llvm-objcopy not found" \
    && pass "objcopy warning printed when llvm-objcopy absent" \
    || fail "expected objcopy warning in output, got: $out"
rm -rf "$bd" "$kdir"

# ── kmake OBJCOPY arg logic (inline replication from build.sh) ────────────────
begin_test "kmake-args: LLD + llvm-objcopy present → LD and OBJCOPY both set"
LINKER=lld LINKER_OBJCOPY=llvm-objcopy ARCH=x86_64
make_args=()
if [[ ${LINKER:-bfd} == lld ]]; then
    if [[ -n "${LINKER_OBJCOPY:-}" ]]; then
        make_args+=( LD=ld.lld OBJCOPY="$LINKER_OBJCOPY" )
    elif [[ "$ARCH" == x86_64 || "$ARCH" == i386 ]]; then
        make_args+=( LD=ld.lld )
    fi
fi
[[ " ${make_args[*]} " == *" LD=ld.lld "* && " ${make_args[*]} " == *" OBJCOPY=llvm-objcopy "* ]] \
    && pass "LD=ld.lld and OBJCOPY=llvm-objcopy both present" \
    || fail "expected LD+OBJCOPY, got: ${make_args[*]}"

begin_test "kmake-args: LLD + no llvm-objcopy, ARCH=x86_64 → LD set, no OBJCOPY"
LINKER=lld LINKER_OBJCOPY="" ARCH=x86_64
make_args=()
if [[ ${LINKER:-bfd} == lld ]]; then
    if [[ -n "${LINKER_OBJCOPY:-}" ]]; then
        make_args+=( LD=ld.lld OBJCOPY="$LINKER_OBJCOPY" )
    elif [[ "$ARCH" == x86_64 || "$ARCH" == i386 ]]; then
        make_args+=( LD=ld.lld )
    fi
fi
[[ " ${make_args[*]} " == *" LD=ld.lld "* && " ${make_args[*]} " != *"OBJCOPY"* ]] \
    && pass "LD=ld.lld present, no OBJCOPY for x86_64 without llvm-objcopy" \
    || fail "expected LD only, got: ${make_args[*]}"

begin_test "kmake-args: LLD + no llvm-objcopy, ARCH=arm64 → neither LD nor OBJCOPY"
LINKER=lld LINKER_OBJCOPY="" ARCH=arm64
make_args=()
if [[ ${LINKER:-bfd} == lld ]]; then
    if [[ -n "${LINKER_OBJCOPY:-}" ]]; then
        make_args+=( LD=ld.lld OBJCOPY="$LINKER_OBJCOPY" )
    elif [[ "$ARCH" == x86_64 || "$ARCH" == i386 ]]; then
        make_args+=( LD=ld.lld )
    fi
fi
[[ ${#make_args[@]} -eq 0 ]] \
    && pass "no LD or OBJCOPY for arm64 without llvm-objcopy (BFD path)" \
    || fail "expected empty make_args, got: ${make_args[*]}"

begin_test "report: falls back to bfd when LINKER absent"
tmp=$(mktemp -d)
mkdir -p "$tmp/build/defconfig-x86_64"
printf 'STATUS=PASS\n' > "$tmp/build/defconfig-x86_64/build.status"
LINKER_USED=bfd
for _bs in "$tmp/build"/*-*/build.status; do
    [[ -f "$_bs" ]] || continue
    _l=$(grep "^LINKER=" "$_bs" 2>/dev/null | cut -d= -f2 || true)
    if [[ -n "$_l" ]]; then LINKER_USED="$_l"; break; fi
done
[[ "$LINKER_USED" == "bfd" ]] \
    && pass "LINKER_USED=bfd when build.status has no LINKER field" \
    || fail "expected bfd, got '$LINKER_USED'"
rm -rf "$tmp"

finish
