#!/bin/bash
# Config bisect: binary-search a failing archived config to isolate the responsible option(s).
# Called by: make bisect CONFIG_FILE=<archive-path> [DRY_RUN=1] [PINNED_OPTS=CONFIG_X,CONFIG_Y]
# Writes all artifacts to bisect/<timestamp>-<config>-<arch>-<sha256>/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$REPO_DIR/lib/common.sh"

# ── Env / defaults ────────────────────────────────────────────────────────────

CONFIG_FILE="${CONFIG_FILE:?CONFIG_FILE= is required. See: make help}"
DRY_RUN="${DRY_RUN:-0}"
PINNED_OPTS="${PINNED_OPTS:-}"  # comma-separated options always present in test steps but not baseline
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build}"
CACHE_DIR="${CACHE_DIR:-$REPO_DIR/cache}"
KERNEL_TREE="${KERNEL_TREE:?KERNEL_TREE= is required}"
TIMEOUT="${TIMEOUT:-60}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1200}"
GCC="${GCC:-gcc}"
TOYBOX_VERSION="${TOYBOX_VERSION:-0.8.9}"
BUILD_ONLY_CONFIGS="${BUILD_ONLY_CONFIGS:-allmodconfig randconfig}"

export BUILD_DIR CACHE_DIR KERNEL_TREE TIMEOUT BUILD_TIMEOUT GCC TOYBOX_VERSION BUILD_ONLY_CONFIGS

# ── Filename parsing ──────────────────────────────────────────────────────────
# Format: kconfig-<config>-<arch>-<version>-<sha256>[-FAILURE-TYPE].config
# SHA256 (64 hex chars) is the anchor; everything before it is config/arch/version.

parse_archive_filename() {
    local path="$1"
    local stem
    stem="$(basename "$path" .config)"

    local sha
    sha=$(grep -oE '[0-9a-f]{64}' <<< "$stem" | head -1) \
        || die "No SHA256 found in filename: $stem"

    local before after
    before="${stem%%"$sha"*}"    # "kconfig-rand500config-i386-v7.2-rc4-"
    after="${stem##*"$sha"}"     # "" or "-BOOT_FAIL-timeout"

    before="${before#kconfig-}"  # "rand500config-i386-v7.2-rc4-"
    before="${before%-}"         # strip trailing dash

    local arch=""
    for a in x86_64 arm64 i386; do
        if [[ "$before" == *"-$a-"* || "$before" == *"-$a" ]]; then
            arch="$a"; break
        fi
    done
    [[ -n "$arch" ]] || die "Cannot detect arch from filename: $stem"

    BISECT_CONFIG="${before%%-"$arch"*}"
    BISECT_ARCH="$arch"
    BISECT_SHA256="$sha"  # stored for archive_reproducer filename
    BISECT_FAILURE_TYPE="${after#-}"  # "BOOT_FAIL-timeout", "BUILD_FAIL", etc.
}

is_boot_failure() { [[ "$BISECT_FAILURE_TYPE" == BOOT_FAIL* ]]; }
is_build_failure() { [[ "$BISECT_FAILURE_TYPE" == BUILD_FAIL* || "$BISECT_FAILURE_TYPE" == BUILD_TIMEOUT ]]; }

# ── Baseline config generation ────────────────────────────────────────────────
# Produces a sorted list of CONFIG_X=y lines present in tinyconfig+bootability.

generate_baseline_options() {
    local arch="$1" out="$2"
    local tmp
    tmp="$(mktemp -d)"
    local make_args=(-C "$KERNEL_TREE" "O=$tmp" "ARCH=$arch")
    [[ "$arch" == arm64 ]] && make_args+=("CROSS_COMPILE=aarch64-linux-gnu-")

    make "${make_args[@]}" tinyconfig >> "$tmp/gen.log" 2>&1
    cat "$REPO_DIR/configs/rand500config.config" >> "$tmp/.config"
    make "${make_args[@]}" olddefconfig >> "$tmp/gen.log" 2>&1
    grep "^CONFIG_[A-Z0-9_]*=y" "$tmp/.config" | sort > "$out"
    rm -rf "$tmp"
}

# ── Candidate extraction ──────────────────────────────────────────────────────
# Candidates = options in archived config but not in tinyconfig+bootability baseline.

extract_candidates() {
    local archived="$1" baseline_opts="$2" out="$3"
    grep "^CONFIG_[A-Z0-9_]*=y" "$archived" | sort > "$out.archived"
    comm -23 "$out.archived" "$baseline_opts" > "$out"
    rm "$out.archived"
}

# ── Per-step config generation ────────────────────────────────────────────────
# Produces a full resolved .config: tinyconfig + bootability [+ pinned opts] + option subset.
# Pass with_pinned=0 to omit PINNED_OPTS (used for the baseline sanity check).

generate_step_config() {
    local arch="$1" options_file="$2" out="$3" with_pinned="${4:-1}"
    local tmp
    tmp="$(mktemp -d)"
    local make_args=(-C "$KERNEL_TREE" "O=$tmp" "ARCH=$arch")
    [[ "$arch" == arm64 ]] && make_args+=("CROSS_COMPILE=aarch64-linux-gnu-")

    make "${make_args[@]}" tinyconfig >> "$tmp/gen.log" 2>&1
    cat "$REPO_DIR/configs/rand500config.config" >> "$tmp/.config"
    if [[ -n "$PINNED_OPTS" && "$with_pinned" == 1 ]]; then
        tr ',[:space:]' '\n' <<< "$PINNED_OPTS" | grep -v '^$' >> "$tmp/.config"
    fi
    [[ -s "$options_file" ]] && cat "$options_file" >> "$tmp/.config"
    make "${make_args[@]}" olddefconfig >> "$tmp/gen.log" 2>&1
    cp "$tmp/.config" "$out"
    rm -rf "$tmp"
}

# ── Single build+boot step ────────────────────────────────────────────────────
# Builds (and optionally boots) a generated config.
# Copies all artifacts into step_dir.
# Returns 0 when the original failure is reproduced, 1 when the step passes.

run_step() {
    local step_dir="$1" seed="$2"
    local stamp
    stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local out_dir="$BUILD_DIR/bisect-$BISECT_ARCH"

    mkdir -p "$step_dir"

    # Build
    SEED_CONFIG="$seed" RUN_STAMP="$stamp" \
        "$REPO_DIR/lib/build.sh" bisect "$BISECT_ARCH" \
        > "$step_dir/build.log" 2>&1 || true

    cp "$out_dir/build.status" "$step_dir/build.status" 2>/dev/null || true

    local build_status
    build_status="$(grep "^STATUS=" "$step_dir/build.status" 2>/dev/null \
                    | cut -d= -f2 || echo FAIL)"

    if is_build_failure; then
        local fail_status="FAIL"
        [[ "$BISECT_FAILURE_TYPE" == BUILD_TIMEOUT ]] && fail_status="TIMEOUT"
        if [[ "$build_status" == "$fail_status" ]]; then
            if [[ -z "${ERROR_PATTERN:-}" ]] \
               || grep -qF "$ERROR_PATTERN" "$step_dir/build.log" 2>/dev/null; then
                return 0  # reproduces
            fi
        fi
        return 1  # passes
    fi

    # For BOOT_FAIL: a build failure here is not the original failure → treat as PASS
    if [[ "$build_status" != "PASS" ]]; then
        return 1
    fi

    # Boot
    TIMEOUT="$TIMEOUT" BUILD_DIR="$BUILD_DIR" \
        "$REPO_DIR/lib/vm.sh" bisect "$BISECT_ARCH" \
        >> "$step_dir/build.log" 2>&1 || true

    cp "$out_dir/vm.status"  "$step_dir/vm.status"  2>/dev/null || true
    cp "$out_dir/dmesg.txt"  "$step_dir/dmesg.txt"  2>/dev/null || true

    local boot_status
    boot_status="$(grep "^BOOT=" "$step_dir/vm.status" 2>/dev/null \
                   | cut -d= -f2 || echo FAIL)"
    [[ "$boot_status" == "FAIL" ]]  # returns 0 (reproduces) or 1 (passes)
}

# Write the human-readable per-step summary line.
write_step_txt() {
    local step_dir="$1" label="$2" count="$3" result="$4" reason="${5:-}"
    local msg="$label: $count option(s) → $result"
    [[ -n "$reason" ]] && msg+=" ($reason)"
    printf '%s\n' "$msg" > "$step_dir/step.txt"
    printf '[bisect] %s\n' "$msg"
}

# ── Bisect loop ───────────────────────────────────────────────────────────────

bisect_loop() {
    local -a candidates=("$@")
    local n="${#candidates[@]}"
    local step=0
    local total
    total=$(python3 -c "import math; print(math.ceil(math.log2($n)))" 2>/dev/null \
            || echo "~$(( n / 2 ))")

    while [[ "$n" -gt 1 ]]; do
        (( step++ )) || true
        local mid=$(( n / 2 ))
        local left_dir right_dir
        left_dir="$BISECT_DIR/step-$(printf '%02d' "$step")-left"
        right_dir="$BISECT_DIR/step-$(printf '%02d' "$step")-right"
        mkdir -p "$left_dir" "$right_dir"

        # Always write both halves' option lists
        printf '%s\n' "${candidates[@]:0:$mid}"    > "$left_dir/options.txt"
        printf '%s\n' "${candidates[@]:$mid}"       > "$right_dir/options.txt"

        # ── Resume: skip if left already completed ────────────────────────────
        if [[ -f "$left_dir/result" ]]; then
            local prev
            prev="$(cat "$left_dir/result")"
            info "[bisect] Step $step/$total: resume — left was $prev"
            if [[ "$prev" == FAIL ]]; then
                candidates=("${candidates[@]:0:$mid}")
            else
                candidates=("${candidates[@]:$mid}")
            fi
            n="${#candidates[@]}"
            continue
        fi

        # ── Test left half ────────────────────────────────────────────────────
        local left_seed="$left_dir/seed.config"
        generate_step_config "$BISECT_ARCH" "$left_dir/options.txt" "$left_seed"

        local left_result="PASS" left_reason=""
        if run_step "$left_dir" "$left_seed"; then
            left_result="FAIL"
            left_reason="$(grep "^FAIL_REASON=" "$left_dir/vm.status" 2>/dev/null \
                           | cut -d= -f2- || echo "")"
        fi
        printf '%s\n' "$left_result" > "$left_dir/result"
        write_step_txt "$left_dir" "Step $step/$total left" "$mid" "$left_result" "$left_reason"

        if [[ "$left_result" == FAIL ]]; then
            printf 'skipped (culprit in left half)\n' > "$right_dir/result"
            write_step_txt "$right_dir" "Step $step/$total right" "$(( n - mid ))" \
                "skipped" "culprit in left"
            candidates=("${candidates[@]:0:$mid}")
            n="$mid"
            continue
        fi

        # ── Left passed → test right half ────────────────────────────────────
        local right_seed="$right_dir/seed.config"
        generate_step_config "$BISECT_ARCH" "$right_dir/options.txt" "$right_seed"

        local right_result="PASS" right_reason=""
        if run_step "$right_dir" "$right_seed"; then
            right_result="FAIL"
            right_reason="$(grep "^FAIL_REASON=" "$right_dir/vm.status" 2>/dev/null \
                            | cut -d= -f2- || echo "")"
        fi
        printf '%s\n' "$right_result" > "$right_dir/result"
        write_step_txt "$right_dir" "Step $step/$total right" "$(( n - mid ))" \
            "$right_result" "$right_reason"

        if [[ "$right_result" == FAIL ]]; then
            candidates=("${candidates[@]:$mid}")
            n=$(( n - mid ))
        else
            # Both halves pass: option interaction — narrowest known failing set is candidates[]
            warn "[bisect] Both halves pass at step $step — option interaction detected"
            warn "[bisect] Smallest failing set: $n options (see $BISECT_DIR/minimum_set.txt)"
            printf '%s\n' "${candidates[@]}" > "$BISECT_DIR/minimum_set.txt"
            printf 'interaction\n' > "$BISECT_DIR/result_type.txt"
            return 1
        fi
    done

    printf '%s\n' "${candidates[@]}" > "$BISECT_DIR/suspect.txt"
    printf 'single\n' > "$BISECT_DIR/result_type.txt"
    return 0
}

# ── Minimal reproducer & archive ─────────────────────────────────────────────

archive_reproducer() {
    local config_file="$1"
    local sha256
    sha256="$(sha256sum "$config_file" | cut -d' ' -f1)"
    local base_failure="${BISECT_FAILURE_TYPE:-UNKNOWN}"
    base_failure="${base_failure%%-bisect-from-*}"
    local dest="$REPO_DIR/configs/archive_failed/kconfig-${BISECT_CONFIG}-${BISECT_ARCH}-${BISECT_VERSION:-unknown}-${sha256}-${base_failure}-bisect-from-${BISECT_SHA256}.config"
    cp "$config_file" "$dest"
    info "Minimal reproducer archived: $(basename "$dest")" >&2
    printf '%s\n' "$dest"
}

# ── Main ─────────────────────────────────────────────────────────────────────

parse_archive_filename "$CONFIG_FILE"

KERNEL_VERSION="$(cat "$BUILD_DIR/.kernel-version" 2>/dev/null || echo unknown)"
BISECT_VERSION="$(grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?' <<< \
    "$(basename "$CONFIG_FILE")" | head -1 || echo unknown)"
TIMESTAMP="$(date -u +%Y-%m-%d_%H-%M-%S)"
BISECT_DIR="$REPO_DIR/bisect/${TIMESTAMP}-${BISECT_CONFIG}-${BISECT_ARCH}-${BISECT_SHA256}"
ERROR_PATTERN=""

info "=== Config Bisect ==="
info "Config:       $BISECT_CONFIG / $BISECT_ARCH"
info "Failure:      $BISECT_FAILURE_TYPE"
info "Archived SHA: $BISECT_SHA256 (${CONFIG_FILE})"
info "Bisect dir:   $BISECT_DIR"

# ── Step 0: extract candidates ────────────────────────────────────────────────

BASELINE_OPTS="$BISECT_DIR/.baseline_options.txt"
CANDIDATES_FILE="$BISECT_DIR/.candidates.txt"

mkdir -p "$BISECT_DIR"

if [[ ! -f "$BASELINE_OPTS" ]]; then
    info "Generating tinyconfig+bootability baseline options for $BISECT_ARCH …"
    generate_baseline_options "$BISECT_ARCH" "$BASELINE_OPTS"
fi

if [[ ! -f "$CANDIDATES_FILE" ]]; then
    info "Extracting candidate options (archived − baseline) …"
    extract_candidates "$CONFIG_FILE" "$BASELINE_OPTS" "$CANDIDATES_FILE"
    # Remove pinned options from the search space — they are always present via generate_step_config
    if [[ -n "$PINNED_OPTS" ]]; then
        local_tmp="$(mktemp)"
        tr ',[:space:]' '\n' <<< "$PINNED_OPTS" | grep -v '^$' | sed 's/=.*//' > "$local_tmp"
        grep -vFf "$local_tmp" "$CANDIDATES_FILE" > "${CANDIDATES_FILE}.filtered" || true
        mv "${CANDIDATES_FILE}.filtered" "$CANDIDATES_FILE"
        rm "$local_tmp"
    fi
fi

mapfile -t CANDIDATES < "$CANDIDATES_FILE"
CANDIDATE_COUNT="${#CANDIDATES[@]}"
TOTAL_STEPS="$(python3 -c "import math; print(math.ceil(math.log2(max($CANDIDATE_COUNT,1))))" \
               2>/dev/null || echo "?")"
export TOTAL_STEPS

if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then
    die "No candidate options found — archived config may equal the baseline"
fi

if is_boot_failure; then MINS_PER_STEP=3; else MINS_PER_STEP=2; fi
if [[ "$TOTAL_STEPS" =~ ^[0-9]+$ ]]; then
    ESTIMATED_MINS=$(( TOTAL_STEPS * MINS_PER_STEP ))
    TIME_ESTIMATE="~${ESTIMATED_MINS} min  (at ~${MINS_PER_STEP} min/cycle)"
else
    TIME_ESTIMATE="unknown"
fi

# ── DRY_RUN ───────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == 1 ]]; then
    printf '\n=== Bisect Plan ===\n'
    printf 'Archived config:   %s\n' "$(basename "$CONFIG_FILE")"
    printf 'Failure type:      %s\n' "$BISECT_FAILURE_TYPE"
    printf 'Arch:              %s\n' "$BISECT_ARCH"
    printf 'Candidate options: %d\n' "$CANDIDATE_COUNT"
    [[ -n "$PINNED_OPTS" ]] && printf 'Pinned options:    %s\n' "$PINNED_OPTS"
    printf 'Estimated steps:   ~%s build+boot cycles\n' "$TOTAL_STEPS"
    printf 'Time estimate:     %s\n' "$TIME_ESTIMATE"
    printf 'Bisect dir:        %s\n\n' "$BISECT_DIR"
    printf 'Candidate list:\n'
    cat "$CANDIDATES_FILE"
    exit 0
fi

# ── Step 1: verify baseline passes ───────────────────────────────────────────

BASELINE_DIR="$BISECT_DIR/step-00-baseline"
if [[ ! -f "$BASELINE_DIR/result" ]]; then
    info "Step 0: verifying baseline (tinyconfig+bootability) …"
    mkdir -p "$BASELINE_DIR"
    local_seed="$BASELINE_DIR/seed.config"
    generate_step_config "$BISECT_ARCH" /dev/null "$local_seed" 0

    if is_boot_failure; then
        BUILD_DIR="$BUILD_DIR" CACHE_DIR="$CACHE_DIR" \
            "$REPO_DIR/lib/initramfs.sh" "$BISECT_ARCH" >> "$BASELINE_DIR/build.log" 2>&1 || true
    fi

    baseline_ok=1
    run_step "$BASELINE_DIR" "$local_seed" && baseline_ok=0 || true
    if [[ "$baseline_ok" -eq 0 ]]; then
        write_step_txt "$BASELINE_DIR" "Baseline" 0 "FAIL" "baseline must pass"
        die "Baseline (tinyconfig+bootability) already fails — bisect cannot proceed"
    fi
    write_step_txt "$BASELINE_DIR" "Baseline" 0 "PASS" ""
    printf 'PASS\n' > "$BASELINE_DIR/result"
fi

# ── Step 2: verify full config still fails ────────────────────────────────────

FULL_DIR="$BISECT_DIR/step-00-full"
if [[ ! -f "$FULL_DIR/result" ]]; then
    info "Step 0: verifying full archived config reproduces failure …"
    mkdir -p "$FULL_DIR"
    cp "$CONFIG_FILE" "$FULL_DIR/options.txt"

    full_fails=0
    run_step "$FULL_DIR" "$CONFIG_FILE" && full_fails=1 || true

    if [[ "$full_fails" -eq 0 ]]; then
        write_step_txt "$FULL_DIR" "Full config" "$CANDIDATE_COUNT" "PASS" \
            "failure no longer reproduces — may be fixed in current kernel"
        printf 'PASS\n' > "$FULL_DIR/result"
        die "Full archived config now PASSES on $KERNEL_VERSION — bug may already be fixed"
    fi

    # Capture error pattern for BUILD_FAIL
    if is_build_failure && [[ -z "$ERROR_PATTERN" ]]; then
        ERROR_PATTERN="$(grep -m1 ": error:" "$FULL_DIR/build.log" 2>/dev/null \
                         | sed 's|.*/||;s|:[0-9]*: error:|: error:|' || echo "")"
        [[ -n "$ERROR_PATTERN" ]] && printf '%s\n' "$ERROR_PATTERN" \
            > "$BISECT_DIR/.error_pattern.txt"
    fi

    full_reason="$(grep "^FAIL_REASON=" "$FULL_DIR/vm.status" 2>/dev/null \
                   | cut -d= -f2- || echo "$BISECT_FAILURE_TYPE")"
    write_step_txt "$FULL_DIR" "Full config" "$CANDIDATE_COUNT" "FAIL" "$full_reason"
    printf 'FAIL\n' > "$FULL_DIR/result"
fi

# Load error pattern from prior run if resuming
if [[ -f "$BISECT_DIR/.error_pattern.txt" ]]; then
    ERROR_PATTERN="$(cat "$BISECT_DIR/.error_pattern.txt")"
fi
export ERROR_PATTERN

printf '\n=== Bisect ready ===\n'
printf 'Candidate options: %d\n' "$CANDIDATE_COUNT"
[[ -n "$PINNED_OPTS" ]] && printf 'Pinned options:    %s\n' "$PINNED_OPTS"
printf 'Estimated steps:   ~%s build+boot cycles\n' "$TOTAL_STEPS"
printf 'Time estimate:     %s\n\n' "$TIME_ESTIMATE"

# ── Binary search ─────────────────────────────────────────────────────────────

RESULT_TYPE="unknown"
if bisect_loop "${CANDIDATES[@]}"; then
    RESULT_TYPE="$(cat "$BISECT_DIR/result_type.txt" 2>/dev/null || echo single)"
else
    RESULT_TYPE="interaction"
fi

# ── Result handling ───────────────────────────────────────────────────────────

if [[ "$RESULT_TYPE" == single ]]; then
    SUSPECT="$(cat "$BISECT_DIR/suspect.txt")"
    info "Suspect option: $SUSPECT"
    info "Verifying single-option reproduction …"

    VERIFY_DIR="$BISECT_DIR/step-verify"
    mkdir -p "$VERIFY_DIR"
    verify_seed="$VERIFY_DIR/seed.config"
    printf '%s\n' "$SUSPECT" > "$VERIFY_DIR/options.txt"
    generate_step_config "$BISECT_ARCH" "$VERIFY_DIR/options.txt" "$verify_seed"

    verify_label="Verify (single)"
    [[ -n "$PINNED_OPTS" ]] && verify_label="Verify (pinned+single)"

    if run_step "$VERIFY_DIR" "$verify_seed"; then
        # run_step exits 0 = failure reproduced = suspect confirmed
        write_step_txt "$VERIFY_DIR" "$verify_label" 1 "FAIL" "$SUSPECT confirmed alone"
        printf 'FAIL\n' > "$VERIFY_DIR/result"

        # Generate and archive minimal reproducer
        REPRODUCER="$BISECT_DIR/result.config"
        cp "$verify_seed" "$REPRODUCER"
        archived_path="$(archive_reproducer "$REPRODUCER")"

        printf '\n=== Bisect Result ===\n'
        printf 'Responsible option:  %s\n' "$SUSPECT"
        printf 'Arch:                %s\n' "$BISECT_ARCH"
        printf 'Failure type:        %s\n' "$BISECT_FAILURE_TYPE"
        printf 'Minimal reproducer:  %s\n' "$REPRODUCER"
        printf 'Archived:            %s\n\n' "$archived_path"
        printf 'Draft FINDINGS.md entry:\n\n'
        printf -- '- [ ] **%s causes %s on %s**\n' \
            "$SUSPECT" "$BISECT_FAILURE_TYPE" "$BISECT_ARCH"
        printf '  Kernel: %s. Found by config bisect from %s.\n' \
            "$KERNEL_VERSION" "$(basename "$CONFIG_FILE")"
        printf '  **Reproduce:**\n'
        printf '  ```sh\n'
        printf '  make bisect CONFIG_FILE=%s\n' "$archived_path"
        printf '  ```\n'
    else
        # run_step exits 1 = failure not reproduced = interaction required
        write_step_txt "$VERIFY_DIR" "$verify_label" 1 "PASS" \
            "does not reproduce alone — interaction required"
        printf 'PASS\n' > "$VERIFY_DIR/result"
        RESULT_TYPE="suspect"
    fi
fi

if [[ "$RESULT_TYPE" == suspect ]]; then
    # Build the full pinned set for the next pass: existing pinned + new suspect
    if [[ -n "$PINNED_OPTS" ]]; then
        next_pinned="${PINNED_OPTS},${SUSPECT}"
    else
        next_pinned="$SUSPECT"
    fi

    printf '\n=== Bisect Result (Suspect — interaction required) ===\n'
    printf 'Primary suspect:  %s\n' "$SUSPECT"
    [[ -n "$PINNED_OPTS" ]] && printf 'Already pinned:   %s\n' "$PINNED_OPTS"
    printf 'Arch:             %s\n' "$BISECT_ARCH"
    printf 'Failure type:     %s\n\n' "$BISECT_FAILURE_TYPE"
    printf '%s does not reproduce the failure (even with pinned options present).\n' "$SUSPECT"
    printf 'It requires at least one more co-required option from the discarded halves.\n\n'
    printf 'Next step — re-run bisect with all suspects pinned:\n'
    printf '  make bisect \\\n'
    printf '    CONFIG_FILE=%s \\\n' "$CONFIG_FILE"
    printf '    PINNED_OPTS=%s\n' "$next_pinned"
fi

if [[ "$RESULT_TYPE" == interaction ]]; then
    mapfile -t MIN_SET < "$BISECT_DIR/minimum_set.txt"
    local_word="options"; [[ "${#MIN_SET[@]}" -eq 1 ]] && local_word="option"
    REPRODUCER="$BISECT_DIR/result.config"
    min_seed="$BISECT_DIR/minimum_set_seed.config"
    generate_step_config "$BISECT_ARCH" "$BISECT_DIR/minimum_set.txt" "$min_seed"
    cp "$min_seed" "$REPRODUCER"
    archived_path="$(archive_reproducer "$REPRODUCER")"

    printf '\n=== Bisect Result (Interaction) ===\n'
    printf 'Smallest failing set: %d %s\n' "${#MIN_SET[@]}" "$local_word"
    printf '%s\n' "${MIN_SET[@]}"
    printf '\nArch:           %s\n' "$BISECT_ARCH"
    printf 'Failure type:   %s\n' "$BISECT_FAILURE_TYPE"
    printf 'Minimal config: %s\n' "$REPRODUCER"
    printf 'Archived:       %s\n' "$archived_path"
    printf '\nNote: no single option reproduces alone — two or more options interact.\n'
    if [[ "${#MIN_SET[@]}" -le 10 ]]; then
        printf 'Manual narrowing from %d %s is feasible.\n' "${#MIN_SET[@]}" "$local_word"
    else
        printf 'Re-run bisect on minimum_set.txt to narrow further:\n'
        printf '  cp %s/minimum_set.txt /tmp/min_candidates.txt\n' "$BISECT_DIR"
    fi
fi

printf '\nFull bisect log: %s\n' "$BISECT_DIR"
