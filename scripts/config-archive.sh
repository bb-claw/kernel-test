#!/bin/bash
# Scan all report directories and populate two config archives:
#   configs/archive_passed/  — configs that produced at least one PASS result
#   configs/archive_failed/  — configs that only ever produced FAIL results
#
# Deduplication key: SHA256 fingerprint. "Passed wins": a config that failed in
# one run but later passed appears only in archive_passed/.
# Processes reports in reverse chronological order so the most recent version
# is used in the archive filename.
#
# Designed for cross-clone use: run in kernel-test, kernel-test-stable, and
# kernel-test-stable-rc — each adds its own entries without deleting entries
# contributed by other clones.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_ROOT="$REPO_ROOT/reports"
PASSED_DIR="$REPO_ROOT/configs/archive_passed"
FAILED_DIR="$REPO_ROOT/configs/archive_failed"

info() { printf '[config-archive] %s\n' "$*"; }
warn() { printf '[config-archive] WARN: %s\n' "$*" >&2; }

mkdir -p "$PASSED_DIR" "$FAILED_DIR"

# Associative arrays keyed by sha256.
# Separate arrays avoid IFS/colon separator ambiguity with paths.
declare -A PASS_CONFIG PASS_ARCH PASS_VERSION PASS_PATH
declare -A FAIL_CONFIG FAIL_ARCH FAIL_VERSION FAIL_PATH FAIL_REASON

total_reports=0
total_entries=0
total_pass=0
total_fail=0

# Return field 3 (Build) from the config table row for (config, arch).
# Config table rows: no leading whitespace; field 4 is PASS/FAIL/TIMEOUT/build-only/?.
# Fingerprint table rows: leading whitespace; field 4 is OK or MISMATCH.
# We exclude fingerprint rows by requiring no leading whitespace.
get_build_status() {
    local summary="$1" config="$2" arch="$3"
    awk -v c="$config" -v a="$arch" \
        '$0 !~ /^[[:space:]]/ && $1==c && $2==a { print $3; exit }' \
        "$summary"
}

# Map any reason text to a short slug.
classify_reason_text() {
    local text="$1"
    if grep -qi "panic" <<< "$text"; then
        echo "BOOT_FAIL-kernel-panic"
    elif grep -qi "oops" <<< "$text"; then
        echo "BOOT_FAIL-oops"
    elif grep -qi "Timeout\|did not reach init" <<< "$text"; then
        echo "BOOT_FAIL-timeout"
    elif grep -qi "TEST_DONE\|Init started" <<< "$text"; then
        echo "BOOT_FAIL-no-test-done"
    else
        echo "BOOT_FAIL-unknown"
    fi
}

# Classify BOOT=FAIL: use vmstatus FAIL_REASON first (most reliable),
# fall back to the Notes field in summary.txt.
classify_boot_fail() {
    local summary="$1" config="$2" arch="$3" vmstatus="$4"
    local reason=""
    if [[ -f "$vmstatus" ]]; then
        reason=$(grep '^FAIL_REASON=' "$vmstatus" | cut -d= -f2- || true)
    fi
    if [[ -z "$reason" ]]; then
        reason=$(awk -v c="$config" -v a="$arch" \
            '$0 !~ /^[[:space:]]/ && $1==c && $2==a { print; exit }' \
            "$summary")
    fi
    classify_reason_text "$reason"
}

# Read a key=value field from a vmstatus file; default to 0 if missing.
vmstat_field() {
    local file="$1" key="$2"
    grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2 || echo 0
}

# Return 0 if sha256 is already present in archive_passed/ (any config/arch/version).
in_passed() {
    local f
    for f in "$PASSED_DIR"/kconfig-*-"$1".config; do
        [[ -f "$f" ]] && return 0
    done
    return 1
}

# Return 0 if sha256 is already present in archive_failed/.
in_failed() {
    local f
    for f in "$FAILED_DIR"/kconfig-*-"$1"-*.config; do
        [[ -f "$f" ]] && return 0
    done
    return 1
}

# Process reports newest-first so the most recent version wins in the filename.
while IFS= read -r -d '' report_dir; do
    dirname=$(basename "$report_dir")

    # Skip the baseline symlink
    [[ "$dirname" == "baseline" ]] && continue

    # Skip reports without kconfig files (pre-archive-feature runs)
    shopt -s nullglob
    kconfigs=("$report_dir"/kconfig-*.config)
    shopt -u nullglob
    [[ ${#kconfigs[@]} -eq 0 ]] && continue

    summary="$report_dir/summary.txt"
    [[ -f "$summary" ]] || continue

    # Extract kernel version: last vX.Y-rcN or vX.Y.Z component in dirname.
    # grep exits 1 when no match (e.g. old SHA-based dirname); || true prevents set -e from firing.
    version=$(grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?' <<< "$dirname" | tail -1 || true)
    if [[ -z "$version" ]]; then
        warn "Cannot extract version from $dirname — skipping"
        continue
    fi

    total_reports=$(( total_reports + 1 ))

    for kconfig_file in "${kconfigs[@]}"; do
        total_entries=$(( total_entries + 1 ))
        base=$(basename "$kconfig_file")          # kconfig-rand500config-x86_64.config

        # Parse config and arch from filename
        # Strip prefix kconfig- and suffix -arch.config
        noprefix="${base#kconfig-}"               # rand500config-x86_64.config
        arch="${noprefix##*-}"                    # x86_64.config
        arch="${arch%.config}"                    # x86_64
        config="${noprefix%-${arch}.config}"      # rand500config

        # Get SHA256 from the fingerprint table: match the line ending with this filename.
        # Fall back to computing it from the file itself for pre-archive-feature reports
        # where summary.txt has no fingerprint section.
        sha256=$(grep -m1 "${base}$" "$summary" | awk '{print $3}' || true)
        if [[ -z "$sha256" || ${#sha256} -ne 64 ]]; then
            sha256=$(sha256sum "$kconfig_file" | cut -d' ' -f1)
        fi
        if [[ -z "$sha256" || ${#sha256} -ne 64 ]]; then
            warn "$dirname: no valid SHA256 for $base — skipping"
            continue
        fi

        vmstatus="$report_dir/vmstatus-${config}-${arch}.txt"

        if [[ -f "$vmstatus" ]]; then
            boot=$(vmstat_field "$vmstatus" BOOT)
            tests_fail=$(vmstat_field "$vmstatus" TESTS_FAIL)
            tests_total=$(vmstat_field "$vmstatus" TESTS_TOTAL)
            kunit_fail=$(vmstat_field "$vmstatus" KUNIT_FAIL)
            kunit_pass=$(vmstat_field "$vmstatus" KUNIT_PASS)

            if [[ "$boot" == "PASS" && "$tests_fail" -eq 0 && "$kunit_fail" -eq 0 ]]; then
                total_pass=$(( total_pass + 1 ))
                if [[ -z "${PASS_PATH[$sha256]+set}" ]]; then
                    PASS_CONFIG[$sha256]="$config"
                    PASS_ARCH[$sha256]="$arch"
                    PASS_VERSION[$sha256]="$version"
                    PASS_PATH[$sha256]="$kconfig_file"
                fi
            elif [[ "$boot" == "PASS" && "$kunit_fail" -gt 0 ]]; then
                kunit_total=$(( kunit_pass + kunit_fail ))
                reason="KUNIT_FAIL-${kunit_fail}-of-${kunit_total}"
                total_fail=$(( total_fail + 1 ))
                if [[ -z "${FAIL_PATH[$sha256]+set}" ]]; then
                    FAIL_CONFIG[$sha256]="$config"; FAIL_ARCH[$sha256]="$arch"
                    FAIL_VERSION[$sha256]="$version"; FAIL_PATH[$sha256]="$kconfig_file"
                    FAIL_REASON[$sha256]="$reason"
                fi
            elif [[ "$boot" == "PASS" && "$tests_fail" -gt 0 ]]; then
                reason="TEST_FAIL-${tests_fail}-of-${tests_total}"
                total_fail=$(( total_fail + 1 ))
                if [[ -z "${FAIL_PATH[$sha256]+set}" ]]; then
                    FAIL_CONFIG[$sha256]="$config"; FAIL_ARCH[$sha256]="$arch"
                    FAIL_VERSION[$sha256]="$version"; FAIL_PATH[$sha256]="$kconfig_file"
                    FAIL_REASON[$sha256]="$reason"
                fi
            else
                reason=$(classify_boot_fail "$summary" "$config" "$arch" "$vmstatus")
                total_fail=$(( total_fail + 1 ))
                if [[ -z "${FAIL_PATH[$sha256]+set}" ]]; then
                    FAIL_CONFIG[$sha256]="$config"; FAIL_ARCH[$sha256]="$arch"
                    FAIL_VERSION[$sha256]="$version"; FAIL_PATH[$sha256]="$kconfig_file"
                    FAIL_REASON[$sha256]="$reason"
                fi
            fi
        else
            # No vmstatus: build-only or build failed
            build=$(get_build_status "$summary" "$config" "$arch")
            if [[ "$build" == "PASS" ]]; then
                # Build-only success (allmodconfig, randconfig, kunitrandconfig)
                total_pass=$(( total_pass + 1 ))
                if [[ -z "${PASS_PATH[$sha256]+set}" ]]; then
                    PASS_CONFIG[$sha256]="$config"
                    PASS_ARCH[$sha256]="$arch"
                    PASS_VERSION[$sha256]="$version"
                    PASS_PATH[$sha256]="$kconfig_file"
                fi
            elif [[ "$build" == "TIMEOUT" ]]; then
                total_fail=$(( total_fail + 1 ))
                if [[ -z "${FAIL_PATH[$sha256]+set}" ]]; then
                    FAIL_CONFIG[$sha256]="$config"; FAIL_ARCH[$sha256]="$arch"
                    FAIL_VERSION[$sha256]="$version"; FAIL_PATH[$sha256]="$kconfig_file"
                    FAIL_REASON[$sha256]="BUILD_TIMEOUT"
                fi
            else
                total_fail=$(( total_fail + 1 ))
                if [[ -z "${FAIL_PATH[$sha256]+set}" ]]; then
                    FAIL_CONFIG[$sha256]="$config"; FAIL_ARCH[$sha256]="$arch"
                    FAIL_VERSION[$sha256]="$version"; FAIL_PATH[$sha256]="$kconfig_file"
                    FAIL_REASON[$sha256]="BUILD_FAIL"
                fi
            fi
        fi
    done
done < <(find "$REPORT_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) \
         ! -name "baseline" -print0 | sort -zr)

# Write archive_passed (additive: skip if already present; graduate from failed if needed).
# Never wipes — other clones may have contributed entries not visible in this reports/ dir.
written_pass=0
skipped_pass=0
for sha256 in "${!PASS_PATH[@]}"; do
    if in_passed "$sha256"; then
        skipped_pass=$(( skipped_pass + 1 ))
        continue
    fi
    src="${PASS_PATH[$sha256]}"
    [[ -f "$src" ]] || { warn "Source missing: $src"; continue; }
    # Graduate: remove any failed entry for this sha256 (config now known to pass)
    for f in "$FAILED_DIR"/kconfig-*-"${sha256}"-*.config; do
        [[ -f "$f" ]] && rm "$f"
    done
    dest="$PASSED_DIR/kconfig-${PASS_CONFIG[$sha256]}-${PASS_ARCH[$sha256]}-${PASS_VERSION[$sha256]}-${sha256}.config"
    cp "$src" "$dest"
    written_pass=$(( written_pass + 1 ))
done

# Write archive_failed (additive: only if not already passed or already tracked as failed).
# Checks on-disk state so entries from other clones are respected.
written_fail=0
skipped_fail=0
for sha256 in "${!FAIL_PATH[@]}"; do
    # passed wins — check both in-memory (this run) and on-disk (other clones)
    if [[ -n "${PASS_PATH[$sha256]+set}" ]] || in_passed "$sha256"; then
        continue
    fi
    if in_failed "$sha256"; then
        skipped_fail=$(( skipped_fail + 1 ))
        continue
    fi
    src="${FAIL_PATH[$sha256]}"
    [[ -f "$src" ]] || { warn "Source missing: $src"; continue; }
    dest="$FAILED_DIR/kconfig-${FAIL_CONFIG[$sha256]}-${FAIL_ARCH[$sha256]}-${FAIL_VERSION[$sha256]}-${sha256}-${FAIL_REASON[$sha256]}.config"
    cp "$src" "$dest"
    written_fail=$(( written_fail + 1 ))
done

info "Scanned $total_reports reports — $total_entries config entries ($total_pass pass, $total_fail fail)"
info "archive_passed: $written_pass added, $skipped_pass already present"
info "archive_failed: $written_fail added, $skipped_fail already present"

# Generate index.txt and index.html inside each archive directory.
# Reads from the on-disk archive, so the index reflects entries from all clones.
generate_index() {
    local date_str dir label count f base sha256 rest version config_arch config arch reason
    date_str=$(date '+%Y-%m-%d %H:%M')

    for dir in "$PASSED_DIR" "$FAILED_DIR"; do
        [[ "$dir" == "$PASSED_DIR" ]] && label=PASSED || label=FAILED

        local -a rows=()

        shopt -s nullglob
        local -a files=("$dir"/kconfig-*.config)
        shopt -u nullglob

        for f in "${files[@]}"; do
            base="${f##*/}"; base="${base#kconfig-}"; base="${base%.config}"
            sha256=$(grep -oE '[0-9a-f]{64}' <<< "$base" | head -1 || true)
            [[ -z "$sha256" ]] && continue
            rest="${base%%-${sha256}*}"
            reason="${base##*${sha256}}"; reason="${reason#-}"
            version=$(grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?$' <<< "$rest" || true)
            config_arch="${rest%-${version}}"
            config=""; arch=""
            for known in x86_64 i386 arm64; do
                if [[ "$config_arch" == *"-${known}" ]]; then
                    arch="$known"; config="${config_arch%-${known}}"; break
                fi
            done
            [[ -z "$arch" ]] && continue
            rows+=("${config}|${arch}|${version}|${reason}")
        done

        count=${#rows[@]}
        local sorted_rows=""
        if [[ $count -gt 0 ]]; then
            sorted_rows=$(printf '%s\n' "${rows[@]}" | sort)
        fi

        # Dynamic column widths
        local w_c=6 w_a=4 w_v=7
        if [[ -n "$sorted_rows" ]]; then
            while IFS='|' read -r c a v _r; do
                [[ ${#c} -gt $w_c ]] && w_c=${#c}
                [[ ${#a} -gt $w_a ]] && w_a=${#a}
                [[ ${#v} -gt $w_v ]] && w_v=${#v}
            done <<< "$sorted_rows"
        fi
        local sep
        sep=$(printf '─%.0s' $(seq 1 $((w_c + w_a + w_v + 20))))

        # Plain-text index
        {
            printf 'Config archive — %s  |  %d entries  |  %s\n\n' "$label" "$count" "$date_str"
            if [[ "$label" == FAILED ]]; then
                printf "%-${w_c}s  %-${w_a}s  %-${w_v}s  FAILURE REASON\n" CONFIG ARCH VERSION
                printf '%s\n' "$sep"
                if [[ -n "$sorted_rows" ]]; then
                    while IFS='|' read -r c a v r; do
                        printf "%-${w_c}s  %-${w_a}s  %-${w_v}s  %s\n" "$c" "$a" "$v" "$r"
                    done <<< "$sorted_rows"
                fi
            else
                printf "%-${w_c}s  %-${w_a}s  VERSION\n" CONFIG ARCH
                printf '%s\n' "$sep"
                if [[ -n "$sorted_rows" ]]; then
                    while IFS='|' read -r c a v _r; do
                        printf "%-${w_c}s  %-${w_a}s  %s\n" "$c" "$a" "$v"
                    done <<< "$sorted_rows"
                fi
            fi
        } > "$dir/index.txt"

        # HTML index
        local hclass
        if [[ "$label" == PASSED ]]; then hclass=pass; else hclass=fail; fi
        {
            printf '<!DOCTYPE html>\n<html lang="en">\n<head><meta charset="utf-8">\n'
            printf '<title>Config archive \xe2\x80\x94 %s</title>\n' "$label"
            printf '<style>\n'
            printf 'body{font-family:monospace;margin:2em}\n'
            printf 'h1{font-size:1.1em}\n'
            printf 'table{border-collapse:collapse}\n'
            printf 'th,td{padding:4px 12px;text-align:left;border:1px solid #ccc}\n'
            printf 'th{background:#f0f0f0}\n'
            printf '.pass{color:#080}.fail{color:#c00}\n'
            printf '</style></head>\n<body>\n'
            printf '<h1>Config archive &mdash; <span class="%s">%s</span>' "$hclass" "$label"
            printf ' &nbsp;|&nbsp; %d entries &nbsp;|&nbsp; %s</h1>\n' "$count" "$date_str"
            printf '<table>\n'
            if [[ "$label" == FAILED ]]; then
                printf '<tr><th>Config</th><th>Arch</th><th>Version</th><th>Failure reason</th></tr>\n'
                if [[ -n "$sorted_rows" ]]; then
                    while IFS='|' read -r c a v r; do
                        printf '<tr><td>%s</td><td>%s</td><td>%s</td><td class="fail">%s</td></tr>\n' \
                            "$c" "$a" "$v" "$r"
                    done <<< "$sorted_rows"
                fi
            else
                printf '<tr><th>Config</th><th>Arch</th><th>Version</th></tr>\n'
                if [[ -n "$sorted_rows" ]]; then
                    while IFS='|' read -r c a v _r; do
                        printf '<tr><td>%s</td><td>%s</td><td class="pass">%s</td></tr>\n' \
                            "$c" "$a" "$v"
                    done <<< "$sorted_rows"
                fi
            fi
            printf '</table>\n</body>\n</html>\n'
        } > "$dir/index.html"

        info "index: $label → $count entries → $(basename "$dir")/index.{txt,html}"
    done
}

generate_index
