#!/bin/bash
# Live KPI dashboard for an in-progress kernel-test run.
# Usage: make monitor            — refresh loop in a separate terminal
#        lib/monitor.sh --once   — single snapshot (scripting / CI)
# Reads: $BUILD_DIR/.build-active  $BUILD_DIR/.vm-active  (sentinels from build.sh / vm.sh)
#        /proc/loadavg  ps         (cc1, kbuild-make, QEMU process counts)
#        $REPORT_DIR                (last metrics.txt for delta section)
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

BUILD_DIR="${BUILD_DIR:-$REPO/build}"
DATA_REPO="${DATA_REPO:-$HOME/git/kernel-test-data}"
REPORT_DIR="${REPORT_DIR:-$DATA_REPO/reports}"
INTERVAL=2
_ONCE=0
[[ "${1:-}" == "--once" ]] && _ONCE=1

# ── Helpers ───────────────────────────────────────────────────────────────────

_elapsed_fmt() {
    local mtime now elapsed min sec
    mtime=$(stat -c %Y "$1" 2>/dev/null) || { printf '?'; return; }
    now=$(date +%s)
    elapsed=$(( now - mtime ))
    min=$(( elapsed / 60 )); sec=$(( elapsed % 60 ))
    printf '%dm%02ds' "$min" "$sec"
}

_field() { grep "^${1}=" "$2" 2>/dev/null | cut -d= -f2; }

_fmt_dur() { local s=$1; printf '%dm%02ds' "$(( s / 60 ))" "$(( s % 60 ))"; }

# ── Snapshot + display ────────────────────────────────────────────────────────

_snapshot() {
    # -- Process counts (ps) --
    # grep -c exits 1 when count is 0, which would add a second "0" inside $().
    # Use || var=0 outside $() to handle the non-zero exit without double-capture.
    local cc1_count cc1_cpu kbuild_count qemu_count
    cc1_count=$(ps ax --no-headers -o comm 2>/dev/null | grep -c '^cc1$') || cc1_count=0
    cc1_cpu=$(ps ax --no-headers -o '%cpu comm' 2>/dev/null | awk '/cc1$/{s+=$1}END{printf "%d",s+0}')
    kbuild_count=$(ps ax --no-headers -o args 2>/dev/null | grep -c 'Makefile\.build') || kbuild_count=0
    qemu_count=$(ps ax --no-headers -o comm 2>/dev/null | grep -c '^qemu-system') || qemu_count=0

    # -- Load average --
    local load1
    read -r load1 _ < /proc/loadavg

    # -- Memory utilization --
    local mem_used_g mem_total_g mem_pct _mem_total _mem_avail
    _mem_total=$(grep '^MemTotal:'     /proc/meminfo | awk '{print $2}')
    _mem_avail=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    mem_used_g=$(awk "BEGIN{printf \"%.1f\", ($_mem_total - $_mem_avail)/1048576}")
    mem_total_g=$(awk "BEGIN{printf \"%.1f\", $_mem_total/1048576}")
    mem_pct=$(( (_mem_total - _mem_avail) * 100 / _mem_total ))

    # -- Active builds (sentinel files; content written by build.sh is the -j value) --
    local build_active=() build_done=0
    while IFS= read -r _af; do
        [[ -f $_af ]] || continue
        local _combo _j
        _combo=${_af%/.build-active}; _combo=${_combo#"$BUILD_DIR"/}
        _j=$(cat "$_af" 2>/dev/null)
        build_active+=("${_combo}|${_j:-?}|$(_elapsed_fmt "$_af")")
    done < <(find "$BUILD_DIR" -maxdepth 2 -name '.build-active' 2>/dev/null | sort)
    build_done=$(find "$BUILD_DIR" -maxdepth 2 -name 'build.status' \
        -exec grep -l '^STATUS=\(PASS\|FAIL\|TIMEOUT\)' {} + 2>/dev/null | wc -l || echo 0)

    # -- Active tests (sentinel files) --
    local test_active=() test_done=0 test_wall_elapsed=0
    while IFS= read -r _af; do
        [[ -f $_af ]] || continue
        local _combo
        _combo=${_af%/.vm-active}; _combo=${_combo#"$BUILD_DIR"/}
        test_active+=("$_combo $(_elapsed_fmt "$_af")")
    done < <(find "$BUILD_DIR" -maxdepth 2 -name '.vm-active' 2>/dev/null | sort)
    test_done=$(find "$BUILD_DIR" -maxdepth 2 -name 'vm.status' 2>/dev/null | wc -l || echo 0)

    # -- Test wall time: elapsed since oldest active VM sentinel --
    if [[ ${#test_active[@]} -gt 0 ]]; then
        local _oldest=0 _mt
        while IFS= read -r _af; do
            [[ -f $_af ]] || continue
            _mt=$(stat -c %Y "$_af" 2>/dev/null) || continue
            [[ $_oldest -eq 0 || $_mt -lt $_oldest ]] && _oldest=$_mt
        done < <(find "$BUILD_DIR" -maxdepth 2 -name '.vm-active' 2>/dev/null)
        [[ $_oldest -gt 0 ]] && test_wall_elapsed=$(( $(date +%s) - _oldest ))
    fi

    # -- Run plan (total expected builds / tests; scoped combos for done counts) --
    local build_total=0 test_total=0 _plan_configs="" _plan_archs="" _plan_boot=""
    if [[ -f "$BUILD_DIR/.run-plan" ]]; then
        build_total=$(grep '^BUILD_TOTAL='  "$BUILD_DIR/.run-plan" | cut -d= -f2)
        test_total=$(grep '^TEST_TOTAL='    "$BUILD_DIR/.run-plan" | cut -d= -f2)
        _plan_configs=$(grep '^CONFIGS='    "$BUILD_DIR/.run-plan" | cut -d= -f2)
        _plan_archs=$(grep '^ARCHS='        "$BUILD_DIR/.run-plan" | cut -d= -f2)
        _plan_boot=$(grep '^BOOT_CONFIGS='  "$BUILD_DIR/.run-plan" | cut -d= -f2)
        build_total=${build_total:-0}; test_total=${test_total:-0}
    fi

    # Scope done counts to this run's combos so accumulated prior-run artifacts
    # don't push done > total.
    if [[ -n $_plan_configs && -n $_plan_archs ]]; then
        local _bd=0 _td=0 _c _a _f
        for _c in $_plan_configs; do
            for _a in $_plan_archs; do
                _f="$BUILD_DIR/$_c-$_a/build.status"
                [[ -f $_f ]] && grep -qE '^STATUS=(PASS|FAIL|TIMEOUT)' "$_f" && _bd=$(( _bd + 1 ))
            done
        done
        build_done=$_bd
        for _c in $_plan_boot; do
            for _a in $_plan_archs; do
                _f="$BUILD_DIR/$_c-$_a/vm.status"
                [[ -f $_f ]] && _td=$(( _td + 1 ))
            done
        done
        test_done=$_td
    fi

    # -- Write monitor sample for metrics.sh peak aggregation --
    local _samples="$BUILD_DIR/.monitor-samples"
    if [[ -d $BUILD_DIR ]]; then
        printf '%d BUILDS=%d CC1=%d KBUILD=%d CPU=%d LOAD=%s\n' \
            "$(date +%s)" "${#build_active[@]}" "$cc1_count" "$kbuild_count" "$cc1_cpu" "$load1" \
            >> "$_samples" 2>/dev/null || true
    fi

    # -- Delta vs last metrics.txt --
    local last_metrics last_label prev_build_wall="" prev_ccache=""
    last_metrics=$(find "$REPORT_DIR" -maxdepth 2 -name 'metrics.txt' 2>/dev/null \
        | sort | tail -1)
    last_label=""
    if [[ -n ${last_metrics:-} && -f $last_metrics ]]; then
        last_label=$(basename "$(dirname "$last_metrics")")
        prev_build_wall=$(_field BUILD_WALL_TIME "$last_metrics")
        prev_ccache=$(_field CCACHE_HIT_RATE_PCT "$last_metrics")
    fi

    # -- Render --
    [[ $_ONCE -eq 0 ]] && printf '\033[2J\033[H'   # clear screen (not in --once mode)

    local ts
    ts=$(date '+%H:%M:%S')
    printf '  KERNEL-TEST MONITOR%41s%s\n' '' "$ts"
    printf '  %s\n' "$(printf '─%.0s' {1..60})"
    printf '\n'

    if [[ $build_total -gt 0 ]]; then
        printf '  BUILDS (%d active / %d done / %d total)' "${#build_active[@]}" "$build_done" "$build_total"
    else
        printf '  BUILDS (%d active / %d done)' "${#build_active[@]}" "$build_done"
    fi
    printf '   cc1: %d  kbuild: %d   CPU: %d%%  load: %s  mem: %s/%sG (%d%%)\n' \
        "$cc1_count" "$kbuild_count" "$cc1_cpu" "$load1" \
        "$mem_used_g" "$mem_total_g" "$mem_pct"
    if [[ ${#build_active[@]} -gt 0 ]]; then
        for _entry in "${build_active[@]}"; do
            IFS='|' read -r _combo _j _elapsed <<< "$_entry"
            printf '    %-36s -j%-3s %s\n' "$_combo" "$_j" "$_elapsed"
        done
    else
        printf '    (none)\n'
    fi

    printf '\n'
    if [[ $test_total -gt 0 && $test_wall_elapsed -gt 0 ]]; then
        printf '  TESTS  (%d active / %d done / %d total)   VMs: %d   wall: %s\n' \
            "${#test_active[@]}" "$test_done" "$test_total" "$qemu_count" "$(_fmt_dur "$test_wall_elapsed")"
    elif [[ $test_total -gt 0 ]]; then
        printf '  TESTS  (%d active / %d done / %d total)   VMs: %d\n' \
            "${#test_active[@]}" "$test_done" "$test_total" "$qemu_count"
    elif [[ $test_wall_elapsed -gt 0 ]]; then
        printf '  TESTS  (%d active / %d done)   VMs: %d   wall: %s\n' \
            "${#test_active[@]}" "$test_done" "$qemu_count" "$(_fmt_dur "$test_wall_elapsed")"
    else
        printf '  TESTS  (%d active / %d done)   VMs: %d\n' \
            "${#test_active[@]}" "$test_done" "$qemu_count"
    fi
    if [[ ${#test_active[@]} -gt 0 ]]; then
        for _entry in "${test_active[@]}"; do
            printf '    %-36s %s\n' "${_entry% *}" "${_entry##* }"
        done
    else
        printf '    (none)\n'
    fi

    if [[ -n $last_label ]]; then
        printf '\n  %s\n' "$(printf '─%.0s' {1..60})"
        printf '  vs last run: %s\n' "$last_label"
        [[ -n ${prev_build_wall:-} ]] && \
            printf '    build wall: %s\n' "$(_fmt_dur "$prev_build_wall")"
        [[ -n ${prev_ccache:-} ]] && \
            printf '    ccache hit: %s%%\n' "$prev_ccache"
        printf '  %s\n' "$(printf '─%.0s' {1..60})"
    fi
    printf '\n'
}

# ── Main ──────────────────────────────────────────────────────────────────────

if [[ $_ONCE -eq 1 ]]; then
    _snapshot
    exit 0
fi

printf 'kernel-test monitor — Ctrl-C to exit\n'
while true; do
    _snapshot
    sleep "$INTERVAL"
done
