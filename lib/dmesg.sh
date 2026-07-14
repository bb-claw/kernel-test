#!/bin/bash
set -euo pipefail

VALID_LABELS=(mainline stable longterm linux-next)
L="${1:-mainline}"

valid=0
for lbl in "${VALID_LABELS[@]}"; do
    [[ "$L" == "$lbl" ]] && { valid=1; break; }
done
if [[ $valid -eq 0 ]]; then
    printf 'error: unknown label "%s". Valid: %s\n' "$L" "${VALID_LABELS[*]}" >&2
    exit 2
fi

D=$(date +%Y-%m-%d_%H-%M-%S)
V=$(uname -r | awk -F '.' '{ print $1"."$2 }')
R=$(uname -r)
mkdir -p dmesg
F="dmesg/dmesg-${L}-${V}-${D}-${R}.txt"
A="${F%.txt}-analysis.txt"

printf 'writing dmesg to %s\n' "$F"
sudo dmesg | tee "$F" > /dev/null

# ── Helpers ───────────────────────────────────────────────────────────────────

ISSUE_PAT='error|warn|fail|oops|panic|BUG:|call trace|hung|taint|unable|firmware.*bug|acpi bios error|ccp.*unable|bogus|unhandled wrmsr|deauthenticated|connection to ap.*lost|invalid mac|unknown.*option|unknown.*type'
IGNORE_PAT='BIOS-e820|Reserving |nosave memory|e820: remove|Not removing|available for PCI|thermal governor|Mitigation|STIBP|IBPB|Spectre|Return thunk|usercopy|apparmor initialized|landlock: Up|yama: becoming|LSM support|mitigations:'

extract_issues() {
    grep -iE "$ISSUE_PAT" "$1" | grep -viE "$IGNORE_PAT" \
        | sed 's/^\[[ 0-9.]*\] //' | sort -u || true
}

count_lines() {
    [[ -z "${1:-}" ]] && { echo 0; return; }
    printf '%s\n' "$1" | wc -l | tr -d ' \t'
}

# ── Previous capture (same label) for diff ────────────────────────────────────

PREV=$(find dmesg -maxdepth 1 -name "dmesg-${L}-*.txt" \
        ! -name "*-analysis.txt" ! -name "${F##*/}" \
        -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | awk '{ sub(/^[^ ]+ /, ""); print }' \
    || true)

# ── Analysis ──────────────────────────────────────────────────────────────────

run_analysis() {
    local verdict="CLEAN"

    printf '======================================================================\n'
    printf 'dmesg analysis\n'
    printf 'label:  %s\n' "$L"
    printf 'kernel: %s\n' "$R"
    printf 'date:   %s\n' "$D"
    printf 'file:   %s\n' "$F"
    printf '======================================================================\n\n'

    # ── Errors & Warnings ────────────────────────────────────────────────────
    printf '── Errors & Warnings ────────────────────────────────────────────────\n'

    local critical fwbugs wrmsr_n wrmsr_msrs
    critical=$(grep -iE 'oops:|kernel panic|BUG:|call trace|general protection fault|unable to handle kernel' "$F" || true)
    fwbugs=$(grep -iE '\[firmware.?bug\]|acpi bios error|acpi.*ae_not_found' "$F" || true)
    # WRMSR: deduplicate — show count + unique MSR addresses, not every line
    wrmsr_n=$(grep -c 'unhandled wrmsr' "$F" || echo 0)
    wrmsr_msrs=$(grep -iE 'unhandled wrmsr' "$F" | grep -oE 'WRMSR\(0x[0-9a-fA-F]+\)' | sort -u | tr '\n' ' ' || true)

    if [[ -n "$critical" ]]; then
        printf 'CRITICAL:\n%s\n\n' "$critical"
        verdict="ERRORS"
    fi
    if [[ -n "$fwbugs" ]]; then
        printf 'Firmware / ACPI bugs:\n%s\n\n' "$fwbugs"
        [[ "$verdict" == "CLEAN" ]] && verdict="WARNINGS"
    fi
    if [[ "$wrmsr_n" -gt 0 ]]; then
        printf 'KVM unhandled WRMSR: %s writes  MSRs: %s\n\n' "$wrmsr_n" "${wrmsr_msrs%% }"
        [[ "$verdict" == "CLEAN" ]] && verdict="WARNINGS"
    fi
    [[ -z "$critical" && -z "$fwbugs" && "$wrmsr_n" -eq 0 ]] && printf 'none\n'

    # ── Hardware ─────────────────────────────────────────────────────────────
    printf '\n── Hardware ─────────────────────────────────────────────────────────\n'

    local nvme_issues deauth_n disc_n wifi_err amd_issues nv_issues taint

    # NVMe
    nvme_issues=$(grep -iE 'nvme.*(bogus|invalid|error|fail|timeout|reset)' "$F" || true)
    if [[ -n "$nvme_issues" ]]; then
        printf 'NVMe:\n%s\n\n' "$nvme_issues"
        [[ "$verdict" == "CLEAN" ]] && verdict="WARNINGS"
    else
        local nvme_devs
        nvme_devs=$(grep -oE 'nvme[0-9]+' "$F" | sort -u | tr '\n' ' ' || true)
        printf 'NVMe: OK  (%s)\n' "${nvme_devs:-none detected}"
    fi

    # Wi-Fi
    deauth_n=$(grep -c 'deauthenticated' "$F" || echo 0)
    disc_n=$(grep -c 'Connection to AP.*lost' "$F" || echo 0)
    wifi_err=$(grep -iE 'mt7921.*(error|fail)|invalid mac address' "$F" || true)
    if [[ -n "$wifi_err" || "$deauth_n" -gt 2 || "$disc_n" -gt 1 ]]; then
        printf 'Wi-Fi (mt7921e):\n'
        [[ -n "$wifi_err" ]] && printf '  %s\n' "$wifi_err"
        [[ "$deauth_n" -gt 0 ]] && printf '  deauth events: %s\n' "$deauth_n"
        [[ "$disc_n" -gt 0 ]] && printf '  AP connection lost: %s\n' "$disc_n"
        printf '\n'
        [[ "$verdict" == "CLEAN" ]] && verdict="WARNINGS"
    else
        printf 'Wi-Fi: OK\n'
    fi

    # AMD platform
    amd_issues=$(grep -iE 'ccp.*(unable|broken bios)|amd.vi.*unknown.*option|amd_pmc.*(fail|error)' "$F" || true)
    if [[ -n "$amd_issues" ]]; then
        printf 'AMD platform:\n%s\n\n' "$amd_issues"
        [[ "$verdict" == "CLEAN" ]] && verdict="WARNINGS"
    else
        printf 'AMD platform: OK\n'
    fi

    # NVIDIA + ideapad
    nv_issues=$(grep -iE 'nvidia.*(error|fail)|drm.*error|ideapad.*(unknown|not available|fail)' "$F" || true)
    taint=$(grep -iE 'out-of-tree module taints|module license.*taints' "$F" | head -1 || true)
    if [[ -n "$nv_issues" || -n "$taint" ]]; then
        printf 'NVIDIA/ideapad:\n'
        [[ -n "$nv_issues" ]] && printf '  %s\n' "$nv_issues"
        [[ -n "$taint" ]] && printf '  kernel tainted (out-of-tree module)\n'
        printf '\n'
        [[ "$verdict" == "CLEAN" ]] && verdict="WARNINGS"
    else
        printf 'NVIDIA/ideapad: OK\n'
    fi

    # ── Diff vs previous ─────────────────────────────────────────────────────
    printf '\n── Diff vs previous ─────────────────────────────────────────────────\n'

    if [[ -n "$PREV" ]]; then
        printf 'previous: %s\n\n' "${PREV##*/}"

        local curr_issues prev_issues new_issues gone_issues new_n gone_n
        curr_issues=$(extract_issues "$F")
        prev_issues=$(extract_issues "$PREV")

        new_issues=$(comm -13 \
            <(printf '%s\n' "$prev_issues" | grep . | sort -u || true) \
            <(printf '%s\n' "$curr_issues"  | grep . | sort -u || true) \
            || true)
        gone_issues=$(comm -23 \
            <(printf '%s\n' "$prev_issues" | grep . | sort -u || true) \
            <(printf '%s\n' "$curr_issues"  | grep . | sort -u || true) \
            || true)

        new_n=$(count_lines "$new_issues")
        gone_n=$(count_lines "$gone_issues")
        printf 'summary: +%s new, -%s resolved\n' "$new_n" "$gone_n"

        if [[ -n "$new_issues" ]]; then
            printf '\nnew:\n'
            printf '%s\n' "$new_issues" | sed 's/^/  + /'
        fi
        if [[ -n "$gone_issues" ]]; then
            printf '\nresolved:\n'
            printf '%s\n' "$gone_issues" | sed 's/^/  - /'
        fi
        [[ -z "$new_issues" && -z "$gone_issues" ]] && printf 'no change\n'
    else
        printf 'no previous capture for label "%s" — skipping diff\n' "$L"
    fi

    # ── Verdict ──────────────────────────────────────────────────────────────
    printf '\n======================================================================\n'
    printf 'VERDICT=%s\n' "$verdict"
    printf '======================================================================\n'
}

run_analysis | tee "$A"

printf '\nanalysis written to %s\n' "$A"

grep -q '^VERDICT=ERRORS' "$A" && exit 1
exit 0
