#!/bin/bash
# Live KPI dashboard for an in-progress kernel-test run.
# Usage: make monitor            — refresh loop in a separate terminal
#        lib/monitor.sh --once   — single snapshot (scripting / CI)
# Reads: $BUILD_DIR/.build-active  $BUILD_DIR/.vm-active  (sentinels from build.sh / vm.sh)
#        /proc/loadavg  ps         (cc1, kbuild-make, QEMU process counts)
#        $REPORT_DIR                (last metrics.txt for delta section)
#        /sys/devices/system/cpu/*/cpufreq  /sys/class/thermal  (throttle warning)
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

_sep() { printf '─%.0s' $(seq 1 "$1"); }

# Prints a WARN line when average CPU freq < 80% of max; silent otherwise.
_check_cpu_throttle() {
    local _max_khz _f _v
    _max_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null) || return 0
    [[ -z ${_max_khz:-} || $_max_khz -eq 0 ]] && return 0
    local _cur_sum=0 _cur_cnt=0
    for _f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        [[ -r $_f ]] || continue
        _v=$(cat "$_f" 2>/dev/null) || continue
        _cur_sum=$(( _cur_sum + _v ))
        _cur_cnt=$(( _cur_cnt + 1 ))
    done
    [[ $_cur_cnt -eq 0 ]] && return 0
    local _avg_khz
    _avg_khz=$(( _cur_sum / _cur_cnt ))
    [[ $_avg_khz -eq 0 ]] && return 0
    local _pct
    _pct=$(( _avg_khz * 100 / _max_khz ))
    [[ $_pct -ge 80 ]] && return 0
    local _cur_ghz _max_ghz
    _cur_ghz=$(awk "BEGIN{printf \"%.1f\", $_avg_khz/1000000}")
    _max_ghz=$(awk "BEGIN{printf \"%.1f\", $_max_khz/1000000}")
    local _tmax=0
    for _f in /sys/class/thermal/thermal_zone*/temp; do
        [[ -r $_f ]] || continue
        _v=$(cat "$_f" 2>/dev/null) || continue
        [[ ${_v:-0} -gt $_tmax ]] && _tmax=$_v
    done
    printf '  WARN: CPU throttled — avg %s GHz / %s GHz max (%d%%)  temp: %d°C\n' \
        "$_cur_ghz" "$_max_ghz" "$_pct" "$(( _tmax / 1000 ))"
}

# ── Snapshot + display ────────────────────────────────────────────────────────

_snapshot() {
    # -- Terminal width: min 60, max 100; _w = usable width (subtract 2-space indent) --
    local _cols _w
    _cols=$(tput cols 2>/dev/null) || _cols=80
    [[ $_cols -lt 60  ]] && _cols=60
    [[ $_cols -gt 100 ]] && _cols=100
    _w=$(( _cols - 2 ))

    # -- Process counts (ps) --
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
        -exec grep -l '^STATUS=\(PASS\|FAIL\|TIMEOUT\)' {} + 2>/dev/null | wc -l 2>/dev/null || true)
    build_done=${build_done:-0}

    # -- Active tests (sentinel files) --
    local test_active=() test_done=0 test_wall_elapsed=0
    while IFS= read -r _af; do
        [[ -f $_af ]] || continue
        local _combo
        _combo=${_af%/.vm-active}; _combo=${_combo#"$BUILD_DIR"/}
        test_active+=("$_combo $(_elapsed_fmt "$_af")")
    done < <(find "$BUILD_DIR" -maxdepth 2 -name '.vm-active' 2>/dev/null | sort)
    test_done=$(find "$BUILD_DIR" -maxdepth 2 -name 'vm.status' 2>/dev/null | wc -l 2>/dev/null || true)
    test_done=${test_done:-0}

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
    local _run_elapsed="" _run_elapsed_secs=0
    if [[ -f "$BUILD_DIR/.run-plan" ]]; then
        build_total=$(grep '^BUILD_TOTAL='  "$BUILD_DIR/.run-plan" | cut -d= -f2)
        test_total=$(grep '^TEST_TOTAL='    "$BUILD_DIR/.run-plan" | cut -d= -f2)
        _plan_configs=$(grep '^CONFIGS='    "$BUILD_DIR/.run-plan" | cut -d= -f2)
        _plan_archs=$(grep '^ARCHS='        "$BUILD_DIR/.run-plan" | cut -d= -f2)
        _plan_boot=$(grep '^BOOT_CONFIGS='  "$BUILD_DIR/.run-plan" | cut -d= -f2)
        build_total=${build_total:-0}; test_total=${test_total:-0}
        _run_elapsed=$(_elapsed_fmt "$BUILD_DIR/.run-plan")
        local _plan_mtime
        _plan_mtime=$(stat -c %Y "$BUILD_DIR/.run-plan" 2>/dev/null) || _plan_mtime=0
        [[ $_plan_mtime -gt 0 ]] && _run_elapsed_secs=$(( $(date +%s) - _plan_mtime ))
    fi

    # Scope done counts to this run's combos so accumulated prior-run artifacts
    # don't push done > total. Only count files written after .run-plan so
    # prior-run artifacts are ignored and done counts only go up.
    if [[ -n $_plan_configs && -n $_plan_archs ]]; then
        local _bd=0 _td=0 _c _a _f _plan_mt _f_mt
        _plan_mt=$(stat -c %Y "$BUILD_DIR/.run-plan" 2>/dev/null) || _plan_mt=0
        for _c in $_plan_configs; do
            for _a in $_plan_archs; do
                _f="$BUILD_DIR/$_c-$_a/build.status"
                [[ -f $_f ]] || continue
                _f_mt=$(stat -c %Y "$_f" 2>/dev/null) || continue
                [[ $_f_mt -ge $_plan_mt ]] && grep -qE '^STATUS=(PASS|FAIL|TIMEOUT)' "$_f" && _bd=$(( _bd + 1 ))
            done
        done
        build_done=$_bd
        for _c in $_plan_boot; do
            for _a in $_plan_archs; do
                _f="$BUILD_DIR/$_c-$_a/vm.status"
                [[ -f $_f ]] || continue
                _f_mt=$(stat -c %Y "$_f" 2>/dev/null) || continue
                [[ $_f_mt -ge $_plan_mt ]] && _td=$(( _td + 1 ))
            done
        done
        test_done=$_td
    fi

    # -- ETA: estimated remaining time based on done/total progress --
    local _eta_sfx=""
    if [[ $_run_elapsed_secs -gt 5 ]]; then
        local _eta_secs=0
        if [[ $build_total -gt 0 && $build_done -gt 0 && $build_done -lt $build_total ]]; then
            _eta_secs=$(( _run_elapsed_secs * (build_total - build_done) / build_done ))
        elif [[ $test_total -gt 0 && $test_done -gt 0 && $test_done -lt $test_total && $test_wall_elapsed -gt 0 ]]; then
            _eta_secs=$(( test_wall_elapsed * (test_total - test_done) / test_done ))
        fi
        [[ $_eta_secs -gt 0 ]] && _eta_sfx=" → ETA ~$(_fmt_dur $_eta_secs)"
    fi

    # -- Write monitor sample for metrics.sh peak aggregation --
    local _samples="$BUILD_DIR/.monitor-samples"
    if [[ -d $BUILD_DIR ]]; then
        printf '%d BUILDS=%d CC1=%d KBUILD=%d CPU=%d LOAD=%s\n' \
            "$(date +%s)" "${#build_active[@]}" "$cc1_count" "$kbuild_count" "$cc1_cpu" "$load1" \
            >> "$_samples" 2>/dev/null || true
    fi

    # -- ccache stats: one --show-stats call per tick covers live delta + all-time display --
    local _cc_dir="${CCACHE_DIR:-$REPO/${CACHE_DIR:-cache}}"
    local _cs_out="" _ccache_live="" _ccache_alltime=""
    local _cc_size_used="?" _cc_size_max="?" _cc_size_pct="?"
    local _cc_direct_n=0 _cc_direct_d=0 _cc_direct_pct=0
    local _cc_prepro_n=0 _cc_prepro_d=0 _cc_prepro_pct=0
    local _cc_errors=0 _cc_cleanups=0

    if [[ -d $_cc_dir ]] && command -v ccache >/dev/null 2>&1; then
        _cs_out=$(CCACHE_DIR="$_cc_dir" ccache --show-stats 2>/dev/null) || _cs_out=""
        if [[ -n $_cs_out ]]; then
            # All-time hit / miss totals (first "Hits:" / "Misses:" under "Cacheable calls:")
            local _hn_abs _hm_abs _ht_abs
            _hn_abs=$(printf '%s' "$_cs_out" | grep -E '^\s*Hits:'   | head -1 | grep -oE '[0-9]+' | head -1); _hn_abs=${_hn_abs:-0}
            _hm_abs=$(printf '%s' "$_cs_out" | grep -E '^\s*Misses:' | head -1 | grep -oE '[0-9]+' | head -1); _hm_abs=${_hm_abs:-0}
            _ht_abs=$(( _hn_abs + _hm_abs ))
            [[ $_ht_abs -gt 0 ]] && _ccache_alltime=$(( _hn_abs * 100 / _ht_abs ))

            # Direct / Preprocessed hit split
            _cc_direct_n=$(printf '%s' "$_cs_out" | grep -E '^\s*Direct:'       | grep -oE '[0-9]+' | sed -n '1p'); _cc_direct_n=${_cc_direct_n:-0}
            _cc_direct_d=$(printf '%s' "$_cs_out" | grep -E '^\s*Direct:'       | grep -oE '[0-9]+' | sed -n '2p'); _cc_direct_d=${_cc_direct_d:-0}
            _cc_prepro_n=$(printf '%s' "$_cs_out" | grep -E '^\s*Preprocessed:' | grep -oE '[0-9]+' | sed -n '1p'); _cc_prepro_n=${_cc_prepro_n:-0}
            _cc_prepro_d=$(printf '%s' "$_cs_out" | grep -E '^\s*Preprocessed:' | grep -oE '[0-9]+' | sed -n '2p'); _cc_prepro_d=${_cc_prepro_d:-0}
            [[ $_cc_direct_d -gt 0 ]] && _cc_direct_pct=$(( _cc_direct_n * 100 / _cc_direct_d ))
            [[ $_cc_prepro_d -gt 0 ]] && _cc_prepro_pct=$(( _cc_prepro_n * 100 / _cc_prepro_d ))

            # Cache size (GB)
            local _cs_line _cs_nums
            _cs_line=$(printf '%s' "$_cs_out" | grep 'Cache size (GB):')
            if [[ -n $_cs_line ]]; then
                _cs_nums=$(printf '%s' "$_cs_line" | grep -oE '[0-9]+\.[0-9]+')
                _cc_size_used=$(printf '%s' "$_cs_nums" | sed -n '1p'); _cc_size_used=${_cc_size_used:-?}
                _cc_size_max=$(printf '%s' "$_cs_nums"  | sed -n '2p'); _cc_size_max=${_cc_size_max:-?}
                local _cc_size_pct_raw
                _cc_size_pct_raw=$(printf '%s' "$_cs_nums" | sed -n '3p')
                _cc_size_pct=${_cc_size_pct_raw%.*}; _cc_size_pct=${_cc_size_pct:-?}
            fi

            # Errors + cleanups
            _cc_errors=$(printf '%s' "$_cs_out"    | grep '^Errors:'       | grep -oE '[0-9]+' | head -1); _cc_errors=${_cc_errors:-0}
            _cc_cleanups=$(printf '%s' "$_cs_out"  | grep '^\s*Cleanups:' | grep -oE '[0-9]+' | head -1); _cc_cleanups=${_cc_cleanups:-0}

            # Live delta (this run): compare with stats captured at build start
            if [[ -f "$BUILD_DIR/.ccache-stats-before" ]]; then
                local _hb _mb _dh _dm _dt
                _hb=$(grep -E '^\s+Hits:'   "$BUILD_DIR/.ccache-stats-before" | head -1 | grep -oE '[0-9]+' | head -1); _hb=${_hb:-0}
                _mb=$(grep -E '^\s+Misses:' "$BUILD_DIR/.ccache-stats-before" | head -1 | grep -oE '[0-9]+' | head -1); _mb=${_mb:-0}
                _dh=$(( _hn_abs - _hb )); [[ $_dh -lt 0 ]] && _dh=0
                _dm=$(( _hm_abs - _mb )); [[ $_dm -lt 0 ]] && _dm=0
                _dt=$(( _dh + _dm ))
                [[ $_dt -gt 0 ]] && _ccache_live=$(( _dh * 100 / _dt ))
            fi
        fi
    fi

    # -- Delta vs last metrics.txt --
    local last_metrics last_label prev_build_wall="" prev_test_wall="" prev_ccache=""
    last_metrics=$(find "$REPORT_DIR" -maxdepth 2 -name 'metrics.txt' \
        -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    last_label=""
    if [[ -n ${last_metrics:-} && -f $last_metrics ]]; then
        last_label=$(basename "$(dirname "$last_metrics")")
        prev_build_wall=$(_field BUILD_WALL_TIME "$last_metrics")
        prev_test_wall=$(_field TEST_WALL_TIME   "$last_metrics")
        prev_ccache=$(_field CCACHE_HIT_RATE_PCT "$last_metrics")
    fi

    # ── Render ────────────────────────────────────────────────────────────────

    [[ $_ONCE -eq 0 ]] && printf '\033[2J\033[H'

    local ts _run_sfx=""
    ts=$(date '+%H:%M:%S')
    [[ -n $_run_elapsed ]] && _run_sfx="   run: $_run_elapsed${_eta_sfx}"
    printf '  KERNEL-TEST MONITOR%41s%s%s\n' '' "$ts" "$_run_sfx"
    printf '  %s\n' "$(_sep "$_w")"
    printf '\n'

    # BUILDS
    if [[ $build_total -gt 0 ]]; then
        printf '  BUILDS (%d active / %d done / %d total)' "${#build_active[@]}" "$build_done" "$build_total"
    else
        printf '  BUILDS (%d active / %d done)' "${#build_active[@]}" "$build_done"
    fi
    printf '   cc1: %d  kbuild: %d   CPU: %d%%  load: %s  mem: %s/%sG (%d%%)\n' \
        "$cc1_count" "$kbuild_count" "$cc1_cpu" "$load1" \
        "$mem_used_g" "$mem_total_g" "$mem_pct"
    _check_cpu_throttle
    if [[ ${#build_active[@]} -gt 0 ]]; then
        for _entry in "${build_active[@]}"; do
            IFS='|' read -r _combo _j _elapsed <<< "$_entry"
            printf '    %-36s -j%-3s %s\n' "$_combo" "$_j" "$_elapsed"
        done
    else
        printf '    (none)\n'
    fi

    # TESTS
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

    # CCACHE
    printf '\n'
    if [[ -n $_cs_out ]]; then
        local _cc_hdr=""
        if [[ -n $_ccache_live ]]; then
            _cc_hdr="this run: ${_ccache_live}%"
            [[ -n $_ccache_alltime ]] && _cc_hdr+="  all-time: ${_ccache_alltime}%"
        elif [[ -n $_ccache_alltime ]]; then
            _cc_hdr="all-time: ${_ccache_alltime}%"
        else
            _cc_hdr="cold"
        fi
        printf '  CCACHE  (%s)   size: %s / %s GB (%s%%)\n' \
            "$_cc_hdr" "$_cc_size_used" "$_cc_size_max" "$_cc_size_pct"
        printf '    direct: %d / %d (%d%%)   preprocessed: %d / %d (%d%%)\n' \
            "$_cc_direct_n" "$_cc_direct_d" "$_cc_direct_pct" \
            "$_cc_prepro_n" "$_cc_prepro_d" "$_cc_prepro_pct"
        printf '    errors: %d   cleanups: %d\n' "$_cc_errors" "$_cc_cleanups"
    else
        printf '  CCACHE  (no data — run make build first or check CCACHE_DIR)\n'
    fi

    # Delta vs last run
    if [[ -n $last_label ]]; then
        printf '\n  %s\n' "$(_sep "$_w")"
        printf '  vs last run: %s\n' "$last_label"
        [[ -n ${prev_build_wall:-} ]] && \
            printf '    build wall: %s\n' "$(_fmt_dur "$prev_build_wall")"
        [[ -n ${prev_test_wall:-} ]] && \
            printf '    test  wall: %s\n' "$(_fmt_dur "$prev_test_wall")"
        [[ -n ${prev_ccache:-} ]] && \
            printf '    ccache hit: %s%%\n' "$prev_ccache"
        printf '  %s\n' "$(_sep "$_w")"
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
