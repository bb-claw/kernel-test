#!/bin/bash
# Extract compiler warnings from build logs and produce a summary.
# Writes per-combo warnings-<config>-<arch>.txt and warnings-summary.txt
# into the latest report dir (or a specified one).
#
# Usage:
#   lib/warnings.sh                        — auto-detect latest report dir
#   lib/warnings.sh REPORT_DIR_PATH        — use a specific report dir
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_env BUILD_DIR CONFIGS ARCHS REPORT_DIR

# ── Resolve report dir ────────────────────────────────────────────────────────

if [[ $# -ge 1 ]]; then
    RUN_DIR="${1%/}"
else
    # Find the most recent dir (excluding symlinks like baseline/warnings-baseline)
    RUN_DIR=$(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d \
        ! -name baseline ! -name warnings-baseline | sort | tail -1)
fi
[[ -n $RUN_DIR && -d $RUN_DIR ]] || die "No report dir found in $REPORT_DIR"

# Extract label from dir basename (first segment before first -)
_rbase="${RUN_DIR##*/}"
_seg="${_rbase%%-*}"
case "$_seg" in
    mainline|stable|longterm|linux-next) LABEL="$_seg" ;;
    *) LABEL=mainline ;;
esac

# Extract version from dir name (part after last timestamp segment)
if [[ $_rbase =~ [0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-(.+)$ ]]; then
    RUN_VERSION="${BASH_REMATCH[1]}"
else
    RUN_VERSION="$_rbase"
fi

info "Warnings analysis → $RUN_DIR/"

# ── Per-combo extraction ──────────────────────────────────────────────────────

# strip_build_prefix LINE BUILD_DIR — replace absolute build dir path with relative path
strip_build_prefix() {
    local line="$1" bdir="$2"
    # Remove leading build dir prefix so paths are repo-relative
    printf '%s\n' "${line/"$bdir/"/}"
}

declare -A COMBO_COUNTS=()

for config in $CONFIGS; do
    for arch in $ARCHS; do
        combo="${config}-${arch}"
        build_out="$BUILD_DIR/$combo"
        build_log="$build_out/build.log"
        build_status_file="$build_out/build.status"
        out_file="$RUN_DIR/warnings-${combo}.txt"

        # Only process PASS builds
        if [[ ! -f $build_status_file ]]; then
            COMBO_COUNTS[$combo]="skip"
            continue
        fi
        status=$(grep "^STATUS=" "$build_status_file" 2>/dev/null | head -1 | cut -d= -f2- || true)
        if [[ $status != PASS ]]; then
            COMBO_COUNTS[$combo]="skip"
            continue
        fi

        if [[ ! -f $build_log ]]; then
            COMBO_COUNTS[$combo]=0
            printf '' > "$out_file"
            continue
        fi

        # Extract, strip prefix, sort+dedup into the per-combo file
        # { ... || true; } prevents pipefail from aborting when grep finds no matches
        { grep ': warning:' "$build_log" || true; } \
            | while IFS= read -r line; do strip_build_prefix "$line" "$build_out"; done \
            | sort -u > "$out_file"

        count=$(wc -l < "$out_file")
        COMBO_COUNTS[$combo]=$count
    done
done

# ── Cross-arch divergence ─────────────────────────────────────────────────────
# Flag warnings present on non-x86_64 arches but absent from x86_64 for the same config.

declare -A DIVERGENCE=()   # key=config, value=lines of divergent warnings

for config in $CONFIGS; do
    ref_file="$RUN_DIR/warnings-${config}-x86_64.txt"
    [[ -f $ref_file ]] || continue
    # x86_64 must be a PASS build to be a valid baseline
    [[ ${COMBO_COUNTS["${config}-x86_64"]:-skip} == skip ]] && continue

    div_lines=()
    for arch in $ARCHS; do
        [[ $arch == x86_64 ]] && continue
        combo="${config}-${arch}"
        [[ ${COMBO_COUNTS[$combo]:-skip} == skip ]] && continue
        cmp_file="$RUN_DIR/warnings-${combo}.txt"
        [[ -f $cmp_file ]] || continue

        # Lines in cmp_file but not in ref_file
        while IFS= read -r wline; do
            [[ -n $wline ]] || continue
            div_lines+=("  ${arch}: ${wline}")
        done < <(comm -23 <(sort "$cmp_file") <(sort "$ref_file"))
    done

    if [[ ${#div_lines[@]} -gt 0 ]]; then
        DIVERGENCE[$config]=$(printf '%s\n' "${div_lines[@]}")
    fi
done

# ── Between-run diff ──────────────────────────────────────────────────────────

_prev_run=''
mapfile -t _all_runs < <(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d \
    ! -name baseline ! -name warnings-baseline | sort)
for _d in "${_all_runs[@]}"; do
    [[ "$_d" == "$RUN_DIR" ]] && continue
    _dseg="${_d##*/}"; _dseg="${_dseg%%-*}"
    case "$_dseg" in mainline|stable|longterm|linux-next) _dlabel="$_dseg" ;; *) _dlabel=mainline ;; esac
    [[ "$_dlabel" == "$LABEL" ]] && _prev_run="$_d"
done

# Extract version from a report dir name
_dir_version() {
    local b="${1##*/}"
    if [[ $b =~ [0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-(.+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "${b##*_}"
    fi
}

# diff_warning_files OLD_DIR NEW_DIR OUTPUT_FILE LABEL_OLD LABEL_NEW
diff_warning_files() {
    local old_dir="$1" new_dir="$2" out="$3" ver_old="$4" ver_new="$5"
    local new_lines=() fixed_lines=()

    for config in $CONFIGS; do
        for arch in $ARCHS; do
            combo="${config}-${arch}"
            old_f="$old_dir/warnings-${combo}.txt"
            new_f="$new_dir/warnings-${combo}.txt"
            [[ -f $new_f ]] || continue
            if [[ ! -f $old_f ]]; then
                # All warnings in new are "new"
                while IFS= read -r w; do
                    [[ -n $w ]] && new_lines+=("  ${combo}: ${w}")
                done < "$new_f"
                continue
            fi
            while IFS= read -r w; do
                [[ -n $w ]] && new_lines+=("  ${combo}: ${w}")
            done < <(comm -23 <(sort "$new_f") <(sort "$old_f"))
            while IFS= read -r w; do
                [[ -n $w ]] && fixed_lines+=("  ${combo}: ${w}")
            done < <(comm -23 <(sort "$old_f") <(sort "$new_f"))
        done
    done

    {
        printf 'Warning diff: %s → %s\n' "$ver_old" "$ver_new"
        printf 'Old: %s\n' "$old_dir"
        printf 'New: %s\n\n' "$new_dir"
        if [[ ${#new_lines[@]} -gt 0 ]]; then
            printf 'NEW WARNINGS (%d):\n' "${#new_lines[@]}"
            printf '%s\n' "${new_lines[@]}"
            printf '\n'
        fi
        if [[ ${#fixed_lines[@]} -gt 0 ]]; then
            printf 'FIXED WARNINGS (%d):\n' "${#fixed_lines[@]}"
            printf '%s\n' "${fixed_lines[@]}"
            printf '\n'
        fi
        if [[ ${#new_lines[@]} -eq 0 && ${#fixed_lines[@]} -eq 0 ]]; then
            printf 'No warning changes detected.\n'
        fi
    } | tee "$out"
}

NEW_LINES=() FIXED_LINES=() PREV_VERSION=''
if [[ -n $_prev_run ]]; then
    PREV_VERSION=$(_dir_version "$_prev_run")
    diff_output="$RUN_DIR/warnings-diff-prev.txt"
    diff_warning_files "$_prev_run" "$RUN_DIR" "$diff_output" "$PREV_VERSION" "$RUN_VERSION" > /dev/null
    # Re-collect for inline summary embedding
    for config in $CONFIGS; do
        for arch in $ARCHS; do
            combo="${config}-${arch}"
            old_f="$_prev_run/warnings-${combo}.txt"
            new_f="$RUN_DIR/warnings-${combo}.txt"
            [[ -f $new_f ]] || continue
            if [[ ! -f $old_f ]]; then
                while IFS= read -r w; do [[ -n $w ]] && NEW_LINES+=("  ${combo}: ${w}"); done < "$new_f"
                continue
            fi
            while IFS= read -r w; do [[ -n $w ]] && NEW_LINES+=("  ${combo}: ${w}"); done \
                < <(comm -23 <(sort "$new_f") <(sort "$old_f"))
            while IFS= read -r w; do [[ -n $w ]] && FIXED_LINES+=("  ${combo}: ${w}"); done \
                < <(comm -23 <(sort "$old_f") <(sort "$new_f"))
        done
    done
fi

# Baseline diff
if [[ -L "$REPORT_DIR/warnings-baseline" ]]; then
    _wbase=$(readlink -f "$REPORT_DIR/warnings-baseline" 2>/dev/null || true)
    _wbase="${_wbase%/}"
    _curr=$(readlink -f "$RUN_DIR" 2>/dev/null || echo "$RUN_DIR")
    if [[ -n $_wbase && -d $_wbase && $_wbase != "$_curr" ]]; then
        _bver=$(_dir_version "$_wbase")
        diff_warning_files "$_wbase" "$RUN_DIR" \
            "$RUN_DIR/warnings-diff-baseline.txt" "$_bver" "$RUN_VERSION" > /dev/null
        info "  warnings-diff-baseline.txt written"
    fi
fi

# ── warnings-summary.txt ──────────────────────────────────────────────────────

SUMMARY="$RUN_DIR/warnings-summary.txt"
{
    printf '=== Warning Summary: %s ===\n\n' "$RUN_VERSION"

    printf 'Counts (warnings per combo):\n'
    for config in $CONFIGS; do
        line="  "
        for arch in $ARCHS; do
            combo="${config}-${arch}"
            cnt="${COMBO_COUNTS[$combo]:-skip}"
            if [[ $cnt == skip ]]; then
                line+=$(printf '%-28s' "${combo}: -")
            else
                line+=$(printf '%-28s' "${combo}: ${cnt}")
            fi
        done
        printf '%s\n' "$line"
    done
    printf '\n'

    if [[ -n $_prev_run ]]; then
        printf 'NEW SINCE %s (%d warnings):\n' "$PREV_VERSION" "${#NEW_LINES[@]}"
        if [[ ${#NEW_LINES[@]} -gt 0 ]]; then
            printf '%s\n' "${NEW_LINES[@]}"
        else
            printf '  (none)\n'
        fi
        printf '\n'
        printf 'FIXED SINCE %s (%d warnings):\n' "$PREV_VERSION" "${#FIXED_LINES[@]}"
        if [[ ${#FIXED_LINES[@]} -gt 0 ]]; then
            printf '%s\n' "${FIXED_LINES[@]}"
        else
            printf '  (none)\n'
        fi
        printf '\n'
    else
        printf '(no previous %s run found for diff)\n\n' "$LABEL"
    fi

    # Cross-arch divergence
    total_div=0
    for config in $CONFIGS; do
        [[ -v DIVERGENCE[$config] ]] && total_div=$(( total_div + $(printf '%s\n' "${DIVERGENCE[$config]}" | grep -c .) ))
    done

    printf 'CROSS-ARCH DIVERGENCE (present on non-x86_64 only, %d warnings):\n' "$total_div"
    if [[ $total_div -gt 0 ]]; then
        for config in $CONFIGS; do
            [[ -v DIVERGENCE[$config] ]] || continue
            printf '  [%s]\n' "$config"
            printf '%s\n' "${DIVERGENCE[$config]}"
            printf '\n'
        done
    else
        printf '  (none)\n'
    fi

} > "$SUMMARY"

info "  warnings-summary.txt written"
[[ -n $_prev_run ]] && info "  warnings-diff-prev.txt written"
