#!/bin/bash
# Aggregate per-run KPIs into metrics.txt and append a performance section
# to summary.txt / summary.html.
# Called by lib/report.sh after all builds and tests are complete.
# Usage: lib/metrics.sh <run_dir> [<ccache_stats_before_file>]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

RUN_DIR="${1:?usage: metrics.sh <run_dir> [ccache_stats_before_file]}"
CCACHE_BEFORE="${2:-}"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
METRICS_FILE="$RUN_DIR/metrics.txt"

# Only process combos that belong to this run (CONFIGS × ARCHS).
# When CONFIGS/ARCHS are unset (standalone invocation), all combos are included.
_in_scope() {
    local combo="$1"
    [[ -z ${CONFIGS:-} || -z ${ARCHS:-} ]] && return 0
    local c a
    for c in $CONFIGS; do
        for a in $ARCHS; do
            [[ $combo == "$c-$a" ]] && return 0
        done
    done
    return 1
}

# ── Helpers ───────────────────────────────────────────────────────────────────

_iso_to_epoch() {
    date -d "$1" +%s 2>/dev/null || echo 0
}

_fmt_duration() {
    local s=$1
    printf '%dm%02ds' "$(( s / 60 ))" "$(( s % 60 ))"
}

# ── Build phase timings ───────────────────────────────────────────────────────

declare -A _build_times
_build_first_start=0
_build_last_end=0

for _f in "$BUILD_DIR"/*/build.status; do
    [[ -f $_f ]] || continue
    _combo=${_f%/build.status}; _combo=${_combo#"$BUILD_DIR"/}
    _in_scope "$_combo" || continue
    _status=$(grep '^STATUS=' "$_f" | cut -d= -f2)
    # Skip INFRA_FAIL sentinel — that's a build.sh crash or kill -9, not a completed run.
    [[ $_status == INFRA_FAIL ]] && continue
    _dur=$(grep '^DURATION=' "$_f" | cut -d= -f2)
    _start_iso=$(grep '^START_TIME=' "$_f" | cut -d= -f2)
    [[ -z ${_dur:-} || -z ${_start_iso:-} ]] && continue
    _start_ep=$(_iso_to_epoch "$_start_iso")
    _end_ep=$(( _start_ep + _dur ))
    [[ $_build_first_start -eq 0 || $_start_ep -lt $_build_first_start ]] && _build_first_start=$_start_ep
    [[ $_end_ep -gt $_build_last_end ]] && _build_last_end=$_end_ep
    _build_times[$_combo]=$_dur
done

_build_wall=0
[[ $_build_first_start -gt 0 && $_build_last_end -gt $_build_first_start ]] && \
    _build_wall=$(( _build_last_end - _build_first_start ))

# ── Test phase timings ────────────────────────────────────────────────────────

declare -A _test_times
_test_first_start=0
_test_last_end=0

for _f in "$BUILD_DIR"/*/vm.status; do
    [[ -f $_f ]] || continue
    _combo=${_f%/vm.status}; _combo=${_combo#"$BUILD_DIR"/}
    _in_scope "$_combo" || continue
    _dur=$(grep '^DURATION=' "$_f" | cut -d= -f2)
    _start_iso=$(grep '^START_TIME=' "$_f" | cut -d= -f2)
    [[ -z ${_dur:-} || -z ${_start_iso:-} ]] && continue
    _start_ep=$(_iso_to_epoch "$_start_iso")
    _end_ep=$(( _start_ep + _dur ))
    [[ $_test_first_start -eq 0 || $_start_ep -lt $_test_first_start ]] && _test_first_start=$_start_ep
    [[ $_end_ep -gt $_test_last_end ]] && _test_last_end=$_end_ep
    _test_times[$_combo]=$_dur
done

_test_wall=0
[[ $_test_first_start -gt 0 && $_test_last_end -gt $_test_first_start ]] && \
    _test_wall=$(( _test_last_end - _test_first_start ))

# ── ccache stats (per-run delta) ──────────────────────────────────────────────

_ccache_hits=0
_ccache_misses=0
_ccache_hit_rate=0

_read_ccache_hits() {
    local file="$1"
    [[ -f $file ]] || { echo 0; return; }
    # ccache 4.x: "  Hits:   N / M (X%)"  — first match is the Summary section
    local v
    v=$(grep -E '^\s+Hits:' "$file" | head -1 | grep -oE '[0-9]+' | head -1)
    echo "${v:-0}"
}

_read_ccache_misses() {
    local file="$1"
    [[ -f $file ]] || { echo 0; return; }
    local v
    v=$(grep -E '^\s+Misses:' "$file" | head -1 | grep -oE '[0-9]+' | head -1)
    echo "${v:-0}"
}

if [[ -n $CCACHE_BEFORE && -f $CCACHE_BEFORE ]]; then
    _now_file=$(mktemp)
    ccache -s > "$_now_file" 2>/dev/null || true
    _h_before=$(_read_ccache_hits "$CCACHE_BEFORE")
    _h_after=$(_read_ccache_hits "$_now_file")
    _m_before=$(_read_ccache_misses "$CCACHE_BEFORE")
    _m_after=$(_read_ccache_misses "$_now_file")
    rm -f "$_now_file"
    _ccache_hits=$(( _h_after - _h_before ))
    _ccache_misses=$(( _m_after - _m_before ))
    [[ $_ccache_hits -lt 0 ]] && _ccache_hits=0
    [[ $_ccache_misses -lt 0 ]] && _ccache_misses=0
    _ccache_total=$(( _ccache_hits + _ccache_misses ))
    [[ $_ccache_total -gt 0 ]] && \
        _ccache_hit_rate=$(( _ccache_hits * 100 / _ccache_total ))
fi

# ── Peak job counts from monitor samples (optional) ───────────────────────────

_peak_builds=0; _peak_cc1=0; _peak_kbuild=0; _peak_cpu=0; _peak_load="0.00"
_samples="$BUILD_DIR/.monitor-samples"

if [[ -f $_samples ]]; then
    while IFS= read -r _line; do
        _v=$(printf '%s' "$_line" | grep -oE 'BUILDS=[0-9]+' | cut -d= -f2); [[ -n ${_v:-} && $_v -gt $_peak_builds ]] && _peak_builds=$_v
        _v=$(printf '%s' "$_line" | grep -oE 'CC1=[0-9]+'   | cut -d= -f2); [[ -n ${_v:-} && $_v -gt $_peak_cc1    ]] && _peak_cc1=$_v
        _v=$(printf '%s' "$_line" | grep -oE 'KBUILD=[0-9]+'| cut -d= -f2); [[ -n ${_v:-} && $_v -gt $_peak_kbuild  ]] && _peak_kbuild=$_v
        _v=$(printf '%s' "$_line" | grep -oE 'CPU=[0-9]+'   | cut -d= -f2); [[ -n ${_v:-} && $_v -gt $_peak_cpu     ]] && _peak_cpu=$_v
        _v=$(printf '%s' "$_line" | grep -oE 'LOAD=[0-9.]+' | cut -d= -f2); [[ -n ${_v:-} ]] && _peak_load=$_v
    done < "$_samples"
fi

# ── Write metrics.txt ─────────────────────────────────────────────────────────

{
    printf '# kernel-test run metrics — generated by lib/metrics.sh\n'
    printf 'RUN_STAMP=%s\n' "${RUN_STAMP:-unknown}"
    printf '\n# Build phase\n'
    printf 'BUILD_COMBOS=%d\n' "${#_build_times[@]}"
    printf 'BUILD_WALL_TIME=%d\n' "$_build_wall"
    if [[ ${#_build_times[@]} -gt 0 ]]; then
        printf '\n# Per-combo build times (seconds)\n'
        for _c in $(printf '%s\n' "${!_build_times[@]}" | sort); do
            printf 'BUILD_TIME_%s=%d\n' "${_c//-/_}" "${_build_times[$_c]}"
        done
    fi
    printf '\n# ccache stats (delta for this run)\n'
    printf 'CCACHE_HITS=%d\n'         "$_ccache_hits"
    printf 'CCACHE_MISSES=%d\n'       "$_ccache_misses"
    printf 'CCACHE_HIT_RATE_PCT=%d\n' "$_ccache_hit_rate"
    printf '\n# Test phase\n'
    printf 'TEST_COMBOS=%d\n' "${#_test_times[@]}"
    printf 'TEST_WALL_TIME=%d\n' "$_test_wall"
    if [[ ${#_test_times[@]} -gt 0 ]]; then
        printf '\n# Per-combo test times (seconds)\n'
        for _c in $(printf '%s\n' "${!_test_times[@]}" | sort); do
            printf 'TEST_TIME_%s=%d\n' "${_c//-/_}" "${_test_times[$_c]}"
        done
    fi
    if [[ -f $_samples ]]; then
        printf '\n# Peak job counts (sampled by make monitor)\n'
        printf 'PEAK_BUILD_JOBS=%d\n'   "$_peak_builds"
        printf 'PEAK_CC1_JOBS=%d\n'     "$_peak_cc1"
        printf 'PEAK_KBUILD_MAKES=%d\n' "$_peak_kbuild"
        printf 'PEAK_CPU_PCT=%d\n'      "$_peak_cpu"
        printf 'PEAK_LOAD=%s\n'         "$_peak_load"
    fi
} > "$METRICS_FILE"

# ── Append to summary.txt ─────────────────────────────────────────────────────

TXT="$RUN_DIR/summary.txt"
[[ -f $TXT ]] || { warn "summary.txt not found at $TXT — skipping text section"; exit 0; }

{
    printf '\n══ Build Performance ══════════════════════════════════════════════\n'
    printf '  Build wall time : %s\n' "$(_fmt_duration "$_build_wall")"
    printf '  Test  wall time : %s\n' "$(_fmt_duration "$_test_wall")"
    if [[ $(( _ccache_hits + _ccache_misses )) -gt 0 ]]; then
        printf '  ccache hit rate : %d%%  (%d hits / %d total)\n' \
            "$_ccache_hit_rate" "$_ccache_hits" "$(( _ccache_hits + _ccache_misses ))"
    fi
    if [[ -f $_samples && $_peak_cc1 -gt 0 ]]; then
        printf '  peak cc1 jobs   : %d  (kbuild makes: %d)\n' "$_peak_cc1" "$_peak_kbuild"
        printf '  peak CPU%%       : %d%%  (load: %s)\n' "$_peak_cpu" "$_peak_load"
    fi
    if [[ ${#_build_times[@]} -gt 0 ]]; then
        printf '\n  Per-combo build times:\n'
        for _c in $(printf '%s\n' "${!_build_times[@]}" | sort); do
            printf '    %-36s %ds\n' "$_c" "${_build_times[$_c]}"
        done
    fi
    if [[ ${#_test_times[@]} -gt 0 ]]; then
        printf '\n  Per-combo test times:\n'
        for _c in $(printf '%s\n' "${!_test_times[@]}" | sort); do
            printf '    %-36s %ds\n' "$_c" "${_test_times[$_c]}"
        done
    fi
} >> "$TXT"

# ── Append to summary.html ────────────────────────────────────────────────────

HTML="$RUN_DIR/summary.html"
[[ -f $HTML ]] || exit 0

# Insert before closing </body> tag
_perf_html=$(mktemp)
{
    printf '<h2>Build Performance</h2>\n'
    printf '<table>\n'
    printf '<tr><th>Metric</th><th>Value</th></tr>\n'
    printf '<tr><td>Build wall time</td><td>%s</td></tr>\n' "$(_fmt_duration "$_build_wall")"
    printf '<tr><td>Test wall time</td><td>%s</td></tr>\n'  "$(_fmt_duration "$_test_wall")"
    if [[ $(( _ccache_hits + _ccache_misses )) -gt 0 ]]; then
        printf '<tr><td>ccache hit rate</td><td>%d%% (%d hits / %d total)</td></tr>\n' \
            "$_ccache_hit_rate" "$_ccache_hits" "$(( _ccache_hits + _ccache_misses ))"
    fi
    if [[ -f $_samples && $_peak_cc1 -gt 0 ]]; then
        printf '<tr><td>peak cc1 jobs</td><td>%d</td></tr>\n' "$_peak_cc1"
        printf '<tr><td>peak CPU%%</td><td>%d%%</td></tr>\n'  "$_peak_cpu"
    fi
    printf '</table>\n'
    if [[ ${#_build_times[@]} -gt 0 ]]; then
        printf '<h3>Per-combo build times</h3><table>\n'
        printf '<tr><th>Combo</th><th>Seconds</th></tr>\n'
        for _c in $(printf '%s\n' "${!_build_times[@]}" | sort); do
            printf '<tr><td>%s</td><td>%d</td></tr>\n' "$_c" "${_build_times[$_c]}"
        done
        printf '</table>\n'
    fi
    if [[ ${#_test_times[@]} -gt 0 ]]; then
        printf '<h3>Per-combo test times</h3><table>\n'
        printf '<tr><th>Combo</th><th>Seconds</th></tr>\n'
        for _c in $(printf '%s\n' "${!_test_times[@]}" | sort); do
            printf '<tr><td>%s</td><td>%d</td></tr>\n' "$_c" "${_test_times[$_c]}"
        done
        printf '</table>\n'
    fi
} > "$_perf_html"

# Splice before </body>
sed -i "s|</body>|$(sed 's/[&/\]/\\&/g; s/$/\\n/' "$_perf_html" | tr -d '\n')</body>|" "$HTML" 2>/dev/null || true
rm -f "$_perf_html"

info "metrics written to $METRICS_FILE"
