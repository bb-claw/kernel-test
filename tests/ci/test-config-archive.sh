#!/bin/bash
# Tests for scripts/config-archive.sh — archive naming, dedup, index format.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"
setup_git_stub

# Build a minimal report dir that config-archive.sh will process.
# Args: report_root dir_name config arch sha256 build_status [boot_status]
make_report() {
    local root="$1" name="$2" cfg="$3" arch="$4" sha="$5" build="$6" boot="${7:-}"
    local d="$root/$name"
    mkdir -p "$d"
    local kf="$d/kconfig-${cfg}-${arch}.config"
    printf 'CONFIG_FAKE=y\n' > "$kf"
    {
        printf 'Config           Arch     Build    Boot\n'
        printf '%s  %s  %s  %s\n' "$cfg" "$arch" "$build" "${boot:-build-only}"
        printf '\nConfig fingerprints (sha256):\n'
        printf '  %s  %s  %s  OK  kconfig-%s-%s.config\n' \
            "$cfg" "$arch" "$sha" "$cfg" "$arch"
    } > "$d/summary.txt"
    if [[ -n "$boot" ]]; then
        local vm="$d/vmstatus-${cfg}-${arch}.txt"
        printf 'BOOT=%s\nTESTS_PASS=0\nTESTS_FAIL=0\n' "$boot" > "$vm"
        if [[ "$boot" == "FAIL" ]]; then printf 'FAIL_REASON=No console output (QEMU exit 0)\n' >> "$vm"; fi
    fi
}

# ── PASS config archived in archive_passed ────────────────────────────────────

begin_test "PASS config goes to archive_passed"
setup_data_repo
SHA="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
make_report "$DATA_REPO/reports" "mainline-7.2-2026-01-01_10-00-00-v7.2-rc1" \
    tinyconfig x86_64 "$SHA" PASS PASS

"$REPO/scripts/config-archive.sh" 2>&1

assert_file_exists \
    "$DATA_REPO/configs/archive_passed/kconfig-tinyconfig-x86_64-v7.2-rc1-${SHA}.config" \
    "passed config archived"

# ── FAIL config archived in archive_failed ────────────────────────────────────

begin_test "FAIL config goes to archive_failed"
setup_data_repo
SHA="bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"
make_report "$DATA_REPO/reports" "mainline-7.2-2026-01-01_10-00-00-v7.2-rc1" \
    tinyconfig x86_64 "$SHA" PASS FAIL

"$REPO/scripts/config-archive.sh" 2>&1

found=$(find "$DATA_REPO/configs/archive_failed" -name "kconfig-tinyconfig-x86_64-*${SHA}*")
assert_ne "$found" "" "failed config archived"
assert_contains "$found" "BOOT_FAIL" "failure type in filename"

# ── Passed wins over failed (same SHA) ───────────────────────────────────────

begin_test "passed config wins over failed (same SHA)"
setup_data_repo
SHA="cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
make_report "$DATA_REPO/reports" "mainline-7.2-2026-01-01_10-00-00-v7.2-rc1" \
    tinyconfig x86_64 "$SHA" PASS FAIL
make_report "$DATA_REPO/reports" "mainline-7.2-2026-01-02_10-00-00-v7.2-rc2" \
    tinyconfig x86_64 "$SHA" PASS PASS

"$REPO/scripts/config-archive.sh" 2>&1

assert_file_exists \
    "$DATA_REPO/configs/archive_passed/kconfig-tinyconfig-x86_64-v7.2-rc2-${SHA}.config" \
    "config in archive_passed after later pass"
failed=$(find "$DATA_REPO/configs/archive_failed" -name "*${SHA}*" 2>/dev/null || true)
assert_eq "$failed" "" "config not in archive_failed when also passed"

# ── Index files written ────────────────────────────────────────────────────────

begin_test "index files written after archive"
setup_data_repo
SHA="dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444"
make_report "$DATA_REPO/reports" "mainline-7.2-2026-01-01_10-00-00-v7.2-rc1" \
    tinyconfig x86_64 "$SHA" PASS FAIL

"$REPO/scripts/config-archive.sh" 2>&1

assert_file_exists "$DATA_REPO/configs/archive_failed/index.txt"  "failed index.txt"
assert_file_exists "$DATA_REPO/configs/archive_failed/index.html" "failed index.html"

finish
