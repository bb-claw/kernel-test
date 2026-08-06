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

# arch_cross_compile <arch>
# Prints the CROSS_COMPILE prefix for cross-compile arches, or "" for native (x86_64, i386).
arch_cross_compile() {
    case "$1" in
        arm64) printf '%s' "aarch64-linux-gnu-" ;;
        riscv) printf '%s' "riscv64-linux-gnu-" ;;
        *)     printf '%s' "" ;;
    esac
}

# arch_kernel_image <arch>
# Prints the kernel image filename for an arch (bzImage for x86; Image for arm64/riscv).
arch_kernel_image() {
    case "$1" in
        arm64|riscv) printf '%s' "Image"   ;;
        *)           printf '%s' "bzImage" ;;
    esac
}

# arch_toybox_name <arch>
# Prints the Toybox binary suffix for an arch (matches landley.net download names).
arch_toybox_name() {
    case "$1" in
        x86_64) printf '%s' "x86_64"  ;;
        i386)   printf '%s' "i686"    ;;
        arm64)  printf '%s' "aarch64" ;;
        riscv)  printf '%s' "riscv64" ;;
        *)      die "Unsupported arch for Toybox: $1 (no binary mapping)" ;;
    esac
}

# apply_arch_overlay <dot_config> <configs_dir> <profile> <arch>
# Silently appends <configs_dir>/<profile>-<arch>.config to <dot_config> if the file exists.
apply_arch_overlay() {
    local dot_config="$1" configs_dir="$2" profile="$3" arch="$4"
    local overlay="${configs_dir}/${profile}-${arch}.config"
    [[ -f "$overlay" ]] && cat "$overlay" >> "$dot_config" || true
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

# ── Serial output parsing ─────────────────────────────────────────────────────
# Shared by lib/vm.sh (QEMU) and lib/board.sh (hardware). All functions read
# from a dmesg file and communicate via globals so callers can inspect results.

# parse_serial_output <dmesg_file>
# Parse a captured serial transcript. Sets result globals; safe to call on an
# empty or missing file (all counters stay 0).
# Sets: BOOT_OK PANIC OOPS TEST_DONE
#       PASS_COUNT FAIL_COUNT TESTS_TOTAL FAILED_TESTS
#       KUNIT_PASS KUNIT_FAIL CANARY_EARLY
parse_serial_output() {
    local dmesg_file="$1"
    BOOT_OK=0; PANIC=0; OOPS=0; TEST_DONE=0
    PASS_COUNT=0; FAIL_COUNT=0; TESTS_TOTAL=0; FAILED_TESTS=''
    KUNIT_PASS=0; KUNIT_FAIL=0; CANARY_EARLY=''

    [[ -s $dmesg_file ]] || return 0

    grep -q  'BOOT_OK:'     "$dmesg_file" 2>/dev/null && BOOT_OK=1   || true
    grep -qi 'Kernel panic' "$dmesg_file" 2>/dev/null && PANIC=1     || true
    grep -q  'Oops:'        "$dmesg_file" 2>/dev/null && OOPS=1      || true
    grep -qF 'TEST_DONE'    "$dmesg_file" 2>/dev/null && TEST_DONE=1 || true

    PASS_COUNT=$(grep -c '^< TEST PASS:' "$dmesg_file" 2>/dev/null || true)
    FAIL_COUNT=$(grep -c '^< TEST FAIL:' "$dmesg_file" 2>/dev/null || true)
    PASS_COUNT=${PASS_COUNT:-0}
    FAIL_COUNT=${FAIL_COUNT:-0}
    TESTS_TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
    FAILED_TESTS=$(grep '^< TEST FAIL:' "$dmesg_file" 2>/dev/null \
        | sed 's/^< TEST FAIL: //' | tr '\n' ' ' | sed 's/ $//' || true)
    FAILED_TESTS=${FAILED_TESTS:-}

    # CANARY marker: always scan; distinguish reached/missing/absent.
    # "missing" is only meaningful when CANARY=1 (build was canary-patched).
    if grep -q '\[BOOT_CANARY\]' "$dmesg_file" 2>/dev/null; then
        CANARY_EARLY=reached
    elif [[ "${CANARY:-0}" == 1 ]]; then
        CANARY_EARLY=missing
    fi

    if grep -qE 'KTAP version|# Subtest:' "$dmesg_file" 2>/dev/null; then
        KUNIT_PASS=$(sed 's/\x1b\[[0-9;]*m//g; s/\r//' "$dmesg_file" \
            | grep -cE '^\[[ 0-9.]+\] ok [0-9]+'     || true)
        KUNIT_FAIL=$(sed 's/\x1b\[[0-9;]*m//g; s/\r//' "$dmesg_file" \
            | grep -cE '^\[[ 0-9.]+\] not ok [0-9]+' || true)
        KUNIT_PASS=${KUNIT_PASS:-0}
        KUNIT_FAIL=${KUNIT_FAIL:-0}
    fi
}

# determine_boot_status <dmesg_file> <exit_code> <timeout_occurred>
# Reads globals from parse_serial_output; sets BOOT_STATUS and FAIL_REASON.
# exit_code=124 (QEMU timeout command) or timeout_occurred=1 (board read -t)
# both map to a timeout failure — callers use whichever applies to their boot
# mechanism.
determine_boot_status() {
    local dmesg_file="$1" exit_code="$2" timeout_occurred="$3"
    BOOT_STATUS=FAIL
    FAIL_REASON=''

    if [[ $BOOT_OK -eq 1 && $PANIC -eq 0 && $OOPS -eq 0 ]]; then
        if [[ $TEST_DONE -eq 0 ]]; then
            FAIL_REASON="Init started but TEST_DONE not reached — kernel may have crashed mid-test"
        else
            BOOT_STATUS=PASS
        fi
    elif [[ $PANIC -eq 1 ]]; then
        FAIL_REASON=$(grep -m1 'Kernel panic' "$dmesg_file" 2>/dev/null || echo 'Kernel panic')
    elif [[ $OOPS -eq 1 ]]; then
        FAIL_REASON=$(grep -m1 'Oops:' "$dmesg_file" 2>/dev/null || echo 'Oops')
    elif [[ $exit_code -eq 124 || $timeout_occurred -eq 1 ]]; then
        FAIL_REASON="Timeout — kernel did not reach init"
    elif [[ $exit_code -eq 0 && ! -s $dmesg_file ]]; then
        FAIL_REASON="No console output (exit 0)"
    else
        FAIL_REASON="Did not reach init (exit ${exit_code})"
    fi
}

# write_run_status <status_file> <start_time> <duration>
# Write vm.status KEY=VALUE lines from result globals.
# Caller records start time and computes duration before calling.
write_run_status() {
    local status_file="$1" start_time="$2" duration="$3"
    {
        printf 'BOOT=%s\n'        "$BOOT_STATUS"
        printf 'TEST_DONE=%d\n'   "$TEST_DONE"
        printf 'TESTS_TOTAL=%d\n' "$TESTS_TOTAL"
        printf 'TESTS_PASS=%d\n'  "$PASS_COUNT"
        printf 'TESTS_FAIL=%d\n'  "$FAIL_COUNT"
        printf 'KUNIT_PASS=%d\n'  "$KUNIT_PASS"
        printf 'KUNIT_FAIL=%d\n'  "$KUNIT_FAIL"
        printf 'START_TIME=%s\n'  "$start_time"
        printf 'DURATION=%d\n'    "$duration"
        if [[ -n ${FAIL_REASON:-}  ]]; then printf 'FAIL_REASON=%s\n'  "$FAIL_REASON";  fi
        if [[ -n ${FAILED_TESTS:-} ]]; then printf 'FAILED_TESTS=%s\n' "$FAILED_TESTS"; fi
        if [[ -n ${CANARY_EARLY:-} ]]; then printf 'CANARY_EARLY=%s\n' "$CANARY_EARLY"; fi
    } > "$status_file"
}

# log_run_result <run_label>
# Log the run summary. Returns 0 on full PASS; 1 on PARTIAL or FAIL.
# Callers do: log_run_result "$label" || exit 1
log_run_result() {
    local run_label="$1" kunit_total total_fail _ft
    kunit_total=$(( KUNIT_PASS + KUNIT_FAIL ))
    total_fail=$(( FAIL_COUNT + KUNIT_FAIL ))

    if [[ $BOOT_STATUS == PASS ]]; then
        if [[ $total_fail -eq 0 ]]; then
            if [[ $kunit_total -gt 0 ]]; then
                info "PASS  $run_label — boot OK, tests ${PASS_COUNT}/${TESTS_TOTAL}, kunit ${KUNIT_PASS}/${kunit_total}"
            else
                info "PASS  $run_label — boot OK, tests ${PASS_COUNT}/${TESTS_TOTAL}"
            fi
            return 0
        else
            if [[ $FAIL_COUNT -gt 0 && $KUNIT_FAIL -gt 0 ]]; then
                warn "PARTIAL  $run_label — booted, but ${FAIL_COUNT} test(s) and ${KUNIT_FAIL} kunit test(s) failed"
            elif [[ $FAIL_COUNT -gt 0 ]]; then
                warn "PARTIAL  $run_label — booted, but ${FAIL_COUNT} test(s) failed"
            else
                warn "PARTIAL  $run_label — booted, but ${KUNIT_FAIL} kunit test(s) failed"
            fi
            for _ft in $FAILED_TESTS; do warn "  FAIL: $_ft"; done
            return 1
        fi
    else
        warn "FAIL  $run_label — ${FAIL_REASON}"
        return 1
    fi
}
