#!/bin/bash
# Scan all report directories and populate two config archives:
#   configs/archive_passed/  — configs that produced at least one PASS result
#   configs/archive_failed/  — configs that only ever produced FAIL results
#
# Deduplication key: SHA256 fingerprint. "Passed wins": a config that failed in
# one run but later passed appears only in archive_passed/.
# Processes reports in reverse chronological order so the most recent version
# is used in the archive filename.
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

    # Extract kernel version: last vX.Y-rcN or vX.Y.Z component in dirname
    version=$(grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?' <<< "$dirname" | tail -1)
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

        # Get SHA256 from the fingerprint table: match the line ending with this filename
        sha256=$(grep -m1 "${base}$" "$summary" | awk '{print $3}' || true)
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

# Wipe existing archive contents for a clean regeneration
find "$PASSED_DIR" -name "*.config" -delete 2>/dev/null || true
find "$FAILED_DIR" -name "*.config" -delete 2>/dev/null || true

# Write archive_passed
written_pass=0
for sha256 in "${!PASS_PATH[@]}"; do
    src="${PASS_PATH[$sha256]}"
    [[ -f "$src" ]] || { warn "Source missing: $src"; continue; }
    dest="$PASSED_DIR/kconfig-${PASS_CONFIG[$sha256]}-${PASS_ARCH[$sha256]}-${PASS_VERSION[$sha256]}-${sha256}.config"
    cp "$src" "$dest"
    written_pass=$(( written_pass + 1 ))
done

# Write archive_failed (only if sha256 never passed)
written_fail=0
for sha256 in "${!FAIL_PATH[@]}"; do
    [[ -n "${PASS_PATH[$sha256]+set}" ]] && continue   # passed wins
    src="${FAIL_PATH[$sha256]}"
    [[ -f "$src" ]] || { warn "Source missing: $src"; continue; }
    dest="$FAILED_DIR/kconfig-${FAIL_CONFIG[$sha256]}-${FAIL_ARCH[$sha256]}-${FAIL_VERSION[$sha256]}-${sha256}-${FAIL_REASON[$sha256]}.config"
    cp "$src" "$dest"
    written_fail=$(( written_fail + 1 ))
done

info "Scanned $total_reports reports — $total_entries config entries ($total_pass pass, $total_fail fail)"
info "archive_passed: $written_pass unique configs"
info "archive_failed: $written_fail unique configs (never passed)"
