#!/bin/bash
# Compare two report directories and show per-test regressions and fixes.
# Usage:
#   lib/diff.sh                       — auto-detect latest two runs in REPORT_DIR
#   lib/diff.sh OLD NEW               — compare two specific report dirs
#   lib/diff.sh OLD NEW OUTPUT_FILE   — also write output to a file
set -euo pipefail
. "$(dirname "$0")/common.sh"

REPORT_DIR="${REPORT_DIR:-reports}"

# ── Resolve dirs ──────────────────────────────────────────────────────────────

OUTPUT=''
if [[ $# -eq 0 ]]; then
    mapfile -t _runs < <(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d \
        ! -name baseline | sort)
    [[ ${#_runs[@]} -ge 2 ]] || \
        die "Need at least 2 runs in $REPORT_DIR to diff (found ${#_runs[@]})"
    OLD_DIR="${_runs[-2]}"
    NEW_DIR="${_runs[-1]}"
elif [[ $# -ge 2 && $# -le 3 ]]; then
    OLD_DIR="${1%/}"
    NEW_DIR="${2%/}"
    OUTPUT="${3:-}"
else
    die "Usage: lib/diff.sh [OLD_DIR NEW_DIR [OUTPUT_FILE]]"
fi

[[ -d $OLD_DIR ]] || die "OLD_DIR not found: $OLD_DIR"
[[ -d $NEW_DIR ]] || die "NEW_DIR not found: $NEW_DIR"

# Require at least one vmstatus file in each dir — otherwise nothing to compare.
old_count=$(find "$OLD_DIR" -maxdepth 1 -name 'vmstatus-*.txt' | wc -l)
new_count=$(find "$NEW_DIR" -maxdepth 1 -name 'vmstatus-*.txt' | wc -l)
if [[ $old_count -eq 0 || $new_count -eq 0 ]]; then
    warn "diff: no vmstatus files found in one or both dirs — run is too old or build-only"
    exit 0
fi

# ── Extract kernel version from dir name (everything after last underscore) ───

_ver() { local b; b=$(basename "$1"); printf '%s' "${b##*_}"; }
OLD_VERSION=$(_ver "$OLD_DIR")
NEW_VERSION=$(_ver "$NEW_DIR")

# ── Helper ────────────────────────────────────────────────────────────────────

read_field() { grep "^${2}=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# ── Collect all config/arch keys from both dirs ───────────────────────────────

declare -A OLD_FILES=() NEW_FILES=()

for f in "$OLD_DIR"/vmstatus-*.txt; do
    [[ -f $f ]] || continue
    key="${f##*/vmstatus-}"; key="${key%.txt}"
    OLD_FILES[$key]="$f"
done

for f in "$NEW_DIR"/vmstatus-*.txt; do
    [[ -f $f ]] || continue
    key="${f##*/vmstatus-}"; key="${key%.txt}"
    NEW_FILES[$key]="$f"
done

mapfile -t ALL_KEYS < <(
    { printf '%s\n' "${!OLD_FILES[@]}"; printf '%s\n' "${!NEW_FILES[@]}"; } | sort -u
)

# ── Diff ──────────────────────────────────────────────────────────────────────

REGRESSIONS=()
FIXES=()
UNCHANGED=0
ONLY_OLD=()
ONLY_NEW=()

for key in "${ALL_KEYS[@]}"; do
    arch="${key##*-}"
    cfg="${key%-*}"
    display="${cfg}/${arch}"

    old_f="${OLD_FILES[$key]:-}"
    new_f="${NEW_FILES[$key]:-}"

    if [[ -z $old_f ]]; then
        ONLY_NEW+=("$display")
        continue
    fi
    if [[ -z $new_f ]]; then
        ONLY_OLD+=("$display")
        continue
    fi

    old_boot=$(read_field  "$old_f" BOOT)
    old_tt=$(read_field    "$old_f" TESTS_TOTAL)
    old_kp=$(read_field    "$old_f" KUNIT_PASS)
    old_kf=$(read_field    "$old_f" KUNIT_FAIL)
    old_failed=$(read_field "$old_f" FAILED_TESTS)

    new_boot=$(read_field  "$new_f" BOOT)
    new_tt=$(read_field    "$new_f" TESTS_TOTAL)
    new_kp=$(read_field    "$new_f" KUNIT_PASS)
    new_kf=$(read_field    "$new_f" KUNIT_FAIL)
    new_failed=$(read_field "$new_f" FAILED_TESTS)

    changed=0

    # Boot change
    if [[ ${old_boot:-?} != "${new_boot:-?}" ]]; then
        if [[ ${old_boot:-?} == PASS && ${new_boot:-?} != PASS ]]; then
            REGRESSIONS+=("$(printf '  %-22s  BOOT: %s → %s' "$display" "${old_boot:-?}" "${new_boot:-?}")")
        else
            FIXES+=("$(printf '  %-22s  BOOT: %s → %s' "$display" "${old_boot:-?}" "${new_boot:-?}")")
        fi
        changed=1
    fi

    # Per-test diff (only meaningful when both runs booted)
    if [[ ${old_boot:-?} == PASS && ${new_boot:-?} == PASS ]]; then
        declare -A _old_set=() _new_set=()
        read -ra _old_arr <<< "${old_failed:-}"
        read -ra _new_arr <<< "${new_failed:-}"
        for t in "${_old_arr[@]}"; do [[ -n $t ]] && _old_set[$t]=1; done
        for t in "${_new_arr[@]}"; do [[ -n $t ]] && _new_set[$t]=1; done

        # New failures (regression)
        for t in "${!_new_set[@]}"; do
            if [[ ! -v _old_set[$t] ]]; then
                REGRESSIONS+=("$(printf '  %-22s  %s: PASS → FAIL' "$display" "$t")")
                changed=1
            fi
        done
        # Resolved failures (fix)
        for t in "${!_old_set[@]}"; do
            if [[ ! -v _new_set[$t] ]]; then
                FIXES+=("$(printf '  %-22s  %s: FAIL → PASS' "$display" "$t")")
                changed=1
            fi
        done
        unset _old_set _new_set _old_arr _new_arr

        # Test inventory count change
        if [[ -n ${old_tt:-} && -n ${new_tt:-} && $old_tt != "$new_tt" ]]; then
            REGRESSIONS+=("$(printf '  %-22s  test count: %s → %s' "$display" "$old_tt" "$new_tt")")
            changed=1
        fi

        # KUnit result change
        old_ktotal=$(( ${old_kp:-0} + ${old_kf:-0} ))
        new_ktotal=$(( ${new_kp:-0} + ${new_kf:-0} ))
        if [[ ${old_kf:-0} -ne ${new_kf:-0} ]] || \
           [[ $old_ktotal -ne $new_ktotal && $old_ktotal -gt 0 ]]; then
            local_entry="$(printf '  %-22s  kunit: %s/%s → %s/%s' \
                "$display" "${old_kp:-0}" "$old_ktotal" "${new_kp:-0}" "$new_ktotal")"
            if [[ ${new_kf:-0} -gt ${old_kf:-0} ]]; then
                REGRESSIONS+=("$local_entry")
            else
                FIXES+=("$local_entry")
            fi
            changed=1
        fi
    fi

    [[ $changed -eq 0 ]] && UNCHANGED=$(( UNCHANGED + 1 ))
done

# ── Format output ─────────────────────────────────────────────────────────────

_generate() {
    printf 'Diff: %s → %s\n' "$OLD_VERSION" "$NEW_VERSION"
    printf 'Old:  %s\n' "$OLD_DIR"
    printf 'New:  %s\n' "$NEW_DIR"
    printf 'Compared: %d config/arch combination(s)\n\n' "${#ALL_KEYS[@]}"

    if [[ ${#REGRESSIONS[@]} -gt 0 ]]; then
        printf 'REGRESSIONS (%d):\n' "${#REGRESSIONS[@]}"
        printf '%s\n' "${REGRESSIONS[@]}"
        printf '\n'
    fi

    if [[ ${#FIXES[@]} -gt 0 ]]; then
        printf 'FIXES (%d):\n' "${#FIXES[@]}"
        printf '%s\n' "${FIXES[@]}"
        printf '\n'
    fi

    if [[ ${#ONLY_OLD[@]} -gt 0 ]]; then
        printf 'ONLY IN %s (%d):\n' "$OLD_VERSION" "${#ONLY_OLD[@]}"
        printf '  %s\n' "${ONLY_OLD[@]}"
        printf '\n'
    fi

    if [[ ${#ONLY_NEW[@]} -gt 0 ]]; then
        printf 'ONLY IN %s (%d):\n' "$NEW_VERSION" "${#ONLY_NEW[@]}"
        printf '  %s\n' "${ONLY_NEW[@]}"
        printf '\n'
    fi

    if [[ $UNCHANGED -gt 0 ]]; then
        printf 'UNCHANGED: %d combination(s) — no behavioral change\n\n' "$UNCHANGED"
    fi

    if [[ ${#REGRESSIONS[@]} -eq 0 && ${#FIXES[@]} -eq 0 ]]; then
        printf 'Overall: no behavioral changes detected\n'
    else
        printf 'Overall: %d regression(s), %d fix(es)\n' \
            "${#REGRESSIONS[@]}" "${#FIXES[@]}"
    fi
}

if [[ -n $OUTPUT ]]; then
    _generate | tee "$OUTPUT"
else
    _generate
fi

# Exit 1 when regressions found — useful for scripted checks.
[[ ${#REGRESSIONS[@]} -eq 0 ]]
