#!/bin/bash
# Verify a kernel patch by building FILES with GCC and Clang across ARCHS.
# Optionally compares before/after a base git commit (BASE=<ref>).
# Called by: make verify-patch FILES=... [BASE=...] [COMPILER=gcc|clang|both]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

# ── Required ──────────────────────────────────────────────────────────────────
: "${KERNEL_TREE:?required}"
: "${FILES:?required — e.g. FILES=security/landlock/fs.o}"

# ── Optional with defaults ────────────────────────────────────────────────────
CONFIG="${CONFIG:-allmodconfig}"
COMPILER="${COMPILER:-both}"
ARCHS="${ARCHS:-arm64 x86_64 riscv i386}"
BASE="${BASE:-}"
CLEAN="${CLEAN:-0}"
V="${V:-0}"

# Resolve BUILD_DIR to an absolute path — git worktree add resolves relative
# paths relative to KERNEL_TREE (via -C), not the kernel-test CWD.
_build="${BUILD_DIR:-build}"
[[ "${_build}" = /* ]] || _build="${REPO_ROOT}/${_build}"
VERIFY_DIR="${_build}/verify-patch"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
LOG_DIR="${VERIFY_DIR}/logs-${TIMESTAMP}"

# ── Compiler list ─────────────────────────────────────────────────────────────
case "${COMPILER}" in
    gcc)   compilers=(gcc) ;;
    clang) compilers=(clang) ;;
    both)  compilers=(gcc clang) ;;
    *)     die "COMPILER must be gcc, clang, or both — got: ${COMPILER}" ;;
esac

# ── Print header ──────────────────────────────────────────────────────────────
echo
echo "── verify-patch ──────────────────────────────────────────────────────────────"
echo "  Files:    ${FILES}"
echo "  Config:   ${CONFIG}"
echo "  Compiler: ${COMPILER}"
echo "  Archs:    ${ARCHS}"
if [[ -n "${BASE}" ]]; then
    current_ref="$(git -C "${KERNEL_TREE}" rev-parse --abbrev-ref HEAD)"
    echo "  Base:     ${BASE}  →  ${current_ref}"
fi
echo

# ── git worktree for BASE= ────────────────────────────────────────────────────
base_tree=""
if [[ -n "${BASE}" ]]; then
    base_tree="${VERIFY_DIR}/worktree-base"
    if [[ -d "${base_tree}" ]]; then
        git -C "${KERNEL_TREE}" worktree remove --force "${base_tree}" 2>/dev/null || true
        rm -rf "${base_tree}"
    fi
    git -C "${KERNEL_TREE}" worktree prune 2>/dev/null || true
    git -C "${KERNEL_TREE}" worktree add "${base_tree}" "${BASE}"
    # shellcheck disable=SC2064
    trap "git -C '${KERNEL_TREE}' worktree remove --force '${base_tree}' 2>/dev/null || true; rm -rf '${base_tree}'; git -C '${KERNEL_TREE}' worktree prune 2>/dev/null || true" EXIT
fi

mkdir -p "${LOG_DIR}"

# ── Build one set of FILES ────────────────────────────────────────────────────
# build_files <tree> <build_dir> <arch> <compiler> <log_prefix>
# Returns 0 on success, 1 on failure.
build_files() {
    local tree="$1" build_dir="$2" arch="$3" compiler="$4" log_prefix="$5"
    local setup_log="${log_prefix}.setup.log"
    local build_log="${log_prefix}.log"

    local cross
    cross="$(arch_cross_compile "${arch}")"

    local flags=("-C" "${tree}" "O=${build_dir}" "ARCH=${arch}")
    if [[ "${compiler}" == "clang" ]]; then
        flags+=("LLVM=1")
    elif [[ -n "${cross}" ]]; then
        flags+=("CROSS_COMPILE=${cross}")
    fi
    [[ "${V}" == "1" ]] && flags+=("V=1")

    if [[ "${CLEAN}" == "1" ]]; then
        rm -rf "${build_dir}"
    fi
    mkdir -p "${build_dir}"

    if [[ ! -f "${build_dir}/.config" ]]; then
        MAKEFLAGS='' MAKELEVEL='' make "${flags[@]}" "${CONFIG}"   > "${setup_log}" 2>&1
        MAKEFLAGS='' MAKELEVEL='' make "${flags[@]}" olddefconfig >> "${setup_log}" 2>&1
    fi

    # Remove stale objects to force recompile of changed files
    for f in ${FILES}; do
        rm -f "${build_dir}/${f}"
    done

    # shellcheck disable=SC2086
    MAKEFLAGS='' MAKELEVEL='' make "${flags[@]}" ${FILES} > "${build_log}" 2>&1
}

# ── Count errors in a log file ────────────────────────────────────────────────
count_errors() {
    grep -c ' error:' "$1" 2>/dev/null || true
}

# ── Result storage ────────────────────────────────────────────────────────────
declare -A result_after result_before

# ── Build loop ────────────────────────────────────────────────────────────────
for arch in ${ARCHS}; do
    for compiler in "${compilers[@]}"; do
        combo="${arch}-${compiler}"
        after_dir="${VERIFY_DIR}/${combo}"
        after_log="${LOG_DIR}/${combo}-after"

        printf "  [%s] building after  ... " "${combo}"
        if build_files "${KERNEL_TREE}" "${after_dir}" "${arch}" "${compiler}" "${after_log}"; then
            result_after["${combo}"]="PASS"
            echo "PASS"
        else
            n="$(count_errors "${after_log}.log")"
            result_after["${combo}"]="FAIL:${n}"
            echo "FAIL (${n} errors)"
        fi

        if [[ -n "${base_tree}" ]]; then
            before_dir="${VERIFY_DIR}/${combo}-base"
            before_log="${LOG_DIR}/${combo}-before"

            printf "  [%s] building before ... " "${combo}"
            if build_files "${base_tree}" "${before_dir}" "${arch}" "${compiler}" "${before_log}"; then
                result_before["${combo}"]="PASS"
                echo "PASS"
            else
                n="$(count_errors "${before_log}.log")"
                result_before["${combo}"]="FAIL:${n}"
                echo "FAIL (${n} errors)"
            fi
        fi
    done
done

# ── Compute verdicts (must happen in main shell, not in tee subshell) ─────────
declare -A verdict_map
overall_exit=0
fixed=0
regressions=0

for arch in ${ARCHS}; do
    for compiler in "${compilers[@]}"; do
        combo="${arch}-${compiler}"
        after="${result_after[${combo}]}"

        if [[ -n "${base_tree}" ]]; then
            before="${result_before[${combo}]:-N/A}"
            if [[ "${before}" == "PASS" && "${after}" == "PASS" ]]; then
                verdict_map["${combo}"]="UNCHANGED-PASS"
            elif [[ "${before}" == FAIL:* && "${after}" == "PASS" ]]; then
                verdict_map["${combo}"]="FIXED"
                (( fixed++ )) || true
            elif [[ "${before}" == "PASS" && "${after}" == FAIL:* ]]; then
                verdict_map["${combo}"]="REGRESSION"
                (( regressions++ )) || true
                overall_exit=1
            else
                verdict_map["${combo}"]="UNCHANGED-FAIL"
                overall_exit=1
            fi
        else
            [[ "${after}" == FAIL:* ]] && overall_exit=1
        fi
    done
done

# ── Summary table ─────────────────────────────────────────────────────────────
{
    echo
    echo "── Results ───────────────────────────────────────────────────────────────────"
    if [[ -n "${base_tree}" ]]; then
        printf " %-8s %-8s %-18s %-18s %s\n" "Arch" "Compiler" "Before" "After" "Verdict"
        echo " ──────────────────────────────────────────────────────────────────────────"
    else
        printf " %-8s %-8s %s\n" "Arch" "Compiler" "Result"
        echo " ───────────────────────────────────────"
    fi

    for arch in ${ARCHS}; do
        for compiler in "${compilers[@]}"; do
            combo="${arch}-${compiler}"
            after="${result_after[${combo}]}"
            after_display="$( [[ "${after}" == FAIL:* ]] && echo "${after#FAIL:} errors" || echo "PASS" )"

            if [[ -n "${base_tree}" ]]; then
                before="${result_before[${combo}]:-N/A}"
                before_display="$( [[ "${before}" == FAIL:* ]] && echo "${before#FAIL:} errors" || echo "${before}" )"
                verdict="${verdict_map[${combo}]}"
                printf " %-8s %-8s %-18s %-18s %s\n" \
                    "${arch}" "${compiler}" "${before_display}" "${after_display}" "${verdict}"
            else
                printf " %-8s %-8s %s\n" "${arch}" "${compiler}" "${after_display}"
            fi
        done
    done

    echo
    if [[ -n "${base_tree}" ]]; then
        if (( regressions > 0 )); then
            echo " Overall: REGRESSION — ${fixed} fixed, ${regressions} regressions"
        elif (( fixed > 0 )); then
            echo " Overall: FIXED — ${fixed} combos improved, 0 regressions"
        else
            echo " Overall: UNCHANGED"
        fi
    else
        echo " Overall: $( (( overall_exit == 0 )) && echo PASS || echo FAIL )"
    fi
    echo " Logs:    ${LOG_DIR}/"
    echo
} | tee "${LOG_DIR}/summary.txt"

exit "${overall_exit}"
