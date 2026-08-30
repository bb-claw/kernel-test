#!/bin/bash
# CI test for tests/programs/common.mk and thin per-program Makefiles.
# Structural checks always run. Compile check runs when compilers are available.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

PROG_DIR="$REPO/tests/programs"
COMMON_MK="$REPO/tests/common.mk"

# ── common.mk exists and has canonical content ────────────────────────────────

begin_test "programs-common-mk-present"
assert_file_exists "$COMMON_MK" "tests/common.mk present"
cm=$(cat "$COMMON_MK")
assert_contains "$cm" "-std=c17"                   "CFLAGS_COMMON uses C17"
assert_contains "$cm" "CFLAGS_GCC ?="              "CFLAGS_GCC defined"
assert_contains "$cm" "CFLAGS_CLANG ?="            "CFLAGS_CLANG defined"
assert_contains "$cm" "CFLAGS_VALGRIND_FLAGS ?="   "CFLAGS_VALGRIND_FLAGS defined"
assert_contains "$cm" "-Wall -Wextra -Wpedantic -Werror" "core GCC warning set present"
assert_contains "$cm" "-Wformat=2"                 "extended GCC warning set present"
assert_contains "$cm" "HOST_ONLY"                  "HOST_ONLY mode defined"
assert_contains "$cm" "FLAGS_ONLY"                 "FLAGS_ONLY mode defined"
assert_contains "$cm" "CFLAGS_\$(1)_EXTRA"        "per-arch extra flags hook present"

# ── Each program Makefile is a thin wrapper that includes common.mk ───────────

begin_test "programs-thin-makefiles"
for prog in arena-test perf-event serial-capture snapshot syscall-tests; do
    mk_path="$PROG_DIR/$prog/Makefile"
    assert_file_exists "$mk_path" "$prog/Makefile present"
    mk=$(cat "$mk_path")
    assert_contains "$mk" "include ../../common.mk" "$prog/Makefile includes common.mk"
    assert_contains "$mk" "SRC" "$prog/Makefile declares SRC"
    assert_contains "$mk" "BIN" "$prog/Makefile declares BIN"
done

# ── serial-capture uses HOST_ONLY=1 ──────────────────────────────────────────

begin_test "programs-serial-capture-host-only"
sc_mk=$(cat "$PROG_DIR/serial-capture/Makefile")
assert_contains "$sc_mk" "HOST_ONLY" "serial-capture sets HOST_ONLY"

# ── arena-test uses nolibc (CC_x86_64 := gcc, not musl-gcc) ─────────────────

begin_test "programs-arena-nolibc"
at_mk=$(cat "$PROG_DIR/arena-test/Makefile")
assert_contains "$at_mk" "CC_x86_64" "arena-test overrides CC_x86_64"
assert_contains "$at_mk" "nolibc"    "arena-test references nolibc"
assert_contains "$at_mk" "CFLAGS_arm64_EXTRA" "arena-test sets arm64 extra flags"

# ── ns/Makefile uses FLAGS_ONLY + common.mk ───────────────────────────────────

begin_test "programs-ns-makefile"
ns_mk=$(cat "$REPO/tests/ns/Makefile")
assert_contains "$ns_mk" "include ../common.mk" "ns/Makefile includes common.mk"
assert_contains "$ns_mk" "FLAGS_ONLY" "ns/Makefile sets FLAGS_ONLY"

# ── Compile check (skipped when compilers absent) ─────────────────────────────

begin_test "programs-compile-x86_64"
if ! command -v musl-gcc &>/dev/null || ! command -v musl-clang &>/dev/null; then
    pass "skip: musl-gcc/musl-clang not available — skipping compile check"
elif ! command -v gcc &>/dev/null; then
    pass "skip: gcc not available — skipping compile check"
else
    tmpdir; BUILD_LOG="$_LAST_TMPDIR/build.log"
    if make -C "$PROG_DIR" clean all ARCHES=x86_64 >"$BUILD_LOG" 2>&1; then
        for prog in arena-test perf-event snapshot syscall-tests; do
            assert_file_exists "$PROG_DIR/$prog/bin/x86_64/$prog" \
                "x86_64/$prog GCC binary present"
            assert_file_exists "$PROG_DIR/$prog/bin/x86_64/$prog-clang" \
                "x86_64/$prog Clang quality-gate binary present"
        done
        assert_file_exists "$PROG_DIR/serial-capture/bin/serial-capture" \
            "serial-capture Clang binary present"
        assert_file_exists "$PROG_DIR/serial-capture/bin/serial-capture-gcc" \
            "serial-capture GCC quality-gate binary present"
        pass "all programs compiled for x86_64 (zero warnings)"
    else
        fail "make -C tests/programs ARCHES=x86_64 failed — build log:"
        cat "$BUILD_LOG" >&2
    fi
fi

begin_test "programs-ns-compile-x86_64"
if ! command -v musl-gcc &>/dev/null || ! command -v musl-clang &>/dev/null; then
    pass "skip: musl-gcc/musl-clang not available — skipping ns compile check"
else
    tmpdir; NS_LOG="$_LAST_TMPDIR/ns-build.log"
    NS_DIR="$REPO/tests/ns"
    if make -C "$NS_DIR" clean all ARCHES=x86_64 >"$NS_LOG" 2>&1; then
        for bin in ns-uts ns-ipc ns-pid ns-mount ns-net ns-user ns-cgroup ns-time; do
            assert_file_exists "$NS_DIR/bin/x86_64/$bin" "x86_64/$bin built"
            assert_file_exists "$NS_DIR/bin/x86_64/$bin-clang" \
                "x86_64/$bin-clang quality gate built"
        done
        pass "all ns binaries compiled for x86_64 (zero warnings)"
    else
        fail "make -C tests/ns ARCHES=x86_64 failed — build log:"
        cat "$NS_LOG" >&2
    fi
fi

finish
