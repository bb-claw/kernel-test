#!/bin/bash
# Verify localconfig kernel on real hardware (Lenovo AMD Ryzen 7 5800H laptop).
# Run after booting the localconfig kernel on the physical machine:
#   bash ~/git/kernel-test/tests/hardware/verify.sh
# Exit: 0 = all checks pass, 1 = one or more failures

_fails=0
ok()   { printf 'ok: %s\n'   "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; _fails=$((_fails+1)); }
skip() { printf 'skip: %s\n' "$*"; }

# ── Kernel identity ───────────────────────────────────────────────────────────
KVER=$(uname -r)
[[ $KVER == *localconfig* ]] \
    && ok "kernel version: $KVER" \
    || fail "not a localconfig build (uname -r: $KVER)"

# ── dmesg access ──────────────────────────────────────────────────────────────
# kernel.dmesg_restrict=1 (Manjaro default) blocks non-root reads.
# Detect once; all dmesg checks below skip gracefully if restricted.
DMESG_OK=0
if dmesg &>/dev/null; then
    DMESG_OK=1
else
    skip "dmesg restricted (kernel.dmesg_restrict=1) — re-run with sudo for dmesg checks"
fi

dmesg_grep() { [[ $DMESG_OK -eq 1 ]] && dmesg 2>/dev/null | grep -qiE "$1"; }

# ── dmesg health ──────────────────────────────────────────────────────────────
if [[ $DMESG_OK -eq 1 ]]; then
    if dmesg 2>/dev/null | grep -qiE 'oops:|kernel panic|BUG: (unable|bad|spinlock|scheduling)'; then
        fail "dmesg: oops/panic/BUG detected"
        dmesg 2>/dev/null | grep -iE 'oops:|kernel panic|BUG: ' | head -3 | \
            while IFS= read -r line; do printf '  %s\n' "$line"; done
    else
        ok "dmesg: no oops/panic/BUG"
    fi
else
    skip "dmesg health: skipped (no dmesg access)"
fi

# ── NVMe storage ──────────────────────────────────────────────────────────────
shopt -s nullglob
nvme_devs=(/dev/nvme[0-9])
shopt -u nullglob
if [[ ${#nvme_devs[@]} -ge 1 ]]; then
    for dev in "${nvme_devs[@]}"; do
        name=$(basename "$dev")
        model=$(cat "/sys/class/nvme/$name/model" 2>/dev/null | xargs)
        ok "NVMe: $dev — ${model:-(model unknown)}"
    done
else
    fail "NVMe: no /dev/nvme* devices found"
fi

# ── WiFi — MT7921 ─────────────────────────────────────────────────────────────
if dmesg_grep 'mt7921'; then
    ok "MT7921: driver loaded (dmesg)"
else
    skip "MT7921: dmesg unavailable or driver not logged"
fi

WIFI_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep '^wl' | head -1)
if [[ -n $WIFI_IF ]]; then
    ok "WiFi interface: $WIFI_IF"
else
    fail "WiFi: no wl* interface found"
fi

# ── Bluetooth ─────────────────────────────────────────────────────────────────
# Prefer sysfs presence over dmesg — hci0 appears regardless of dmesg access.
if [[ -d /sys/class/bluetooth/hci0 ]]; then
    ok "Bluetooth: hci0 present in /sys/class/bluetooth/"
else
    fail "Bluetooth: hci0 not found in /sys/class/bluetooth/"
fi

if command -v rfkill &>/dev/null; then
    rfkill list 2>/dev/null | grep -qi bluetooth \
        && ok "Bluetooth: rfkill entry present" \
        || fail "Bluetooth: not found in rfkill list"
else
    skip "Bluetooth rfkill: rfkill not installed"
fi

# btmtk logs vary by kernel version — skip if dmesg restricted
if dmesg_grep 'btmtk|btusb|hci0.*mt|mediatek.*bt|bluetooth.*mt'; then
    ok "Bluetooth: MediaTek driver in dmesg"
else
    skip "Bluetooth dmesg: driver string not found (restricted or log rotated)"
fi

# ── AMD PMC (S2Idle suspend) ──────────────────────────────────────────────────
if dmesg_grep 'amd.pmc|amd_pmc|AMDI000'; then
    ok "AMD PMC: driver loaded (dmesg)"
else
    skip "AMD PMC: dmesg unavailable or driver not logged"
fi

MEM_SLEEP=$(cat /sys/power/mem_sleep 2>/dev/null || true)
if [[ $MEM_SLEEP == *s2idle* ]]; then
    ok "suspend: s2idle available ($MEM_SLEEP)"
else
    fail "suspend: s2idle not available (mem_sleep: ${MEM_SLEEP:-file missing})"
fi

# ── K10TEMP (die temperature) ─────────────────────────────────────────────────
K10_NAME=$(grep -rl 'k10temp' /sys/class/hwmon/*/name 2>/dev/null | head -1)
if [[ -n $K10_NAME ]]; then
    HWMON_DIR=$(dirname "$K10_NAME")
    TEMP=$(cat "$HWMON_DIR/temp1_input" 2>/dev/null || true)
    if [[ -n $TEMP ]]; then
        ok "K10TEMP: $(( TEMP / 1000 ))°C (Tctl)"
    else
        ok "K10TEMP: hwmon entry present (temp read failed)"
    fi
else
    fail "K10TEMP: no hwmon entry found"
fi

# ── IDEAPAD_LAPTOP ────────────────────────────────────────────────────────────
# Check sysfs platform device — more reliable than dmesg.
if [[ -d /sys/bus/platform/drivers/ideapad_acpi ]]; then
    ok "ideapad-laptop: driver bound (ideapad_acpi)"
elif dmesg_grep 'ideapad'; then
    ok "ideapad-laptop: driver loaded (dmesg)"
else
    fail "ideapad-laptop: not found in sysfs or dmesg"
fi

CONS=$(ls /sys/bus/platform/devices/*/conservation_mode 2>/dev/null | head -1)
if [[ -n $CONS ]]; then
    ok "ideapad-laptop: conservation_mode node at $CONS"
else
    skip "ideapad-laptop: conservation_mode node absent (may require specific ACPI firmware)"
fi

# ── AES-NI ────────────────────────────────────────────────────────────────────
if grep -qE '^name\s*:.*aes' /proc/crypto 2>/dev/null; then
    ok "AES-NI: aes present in /proc/crypto"
else
    fail "AES-NI: not found in /proc/crypto"
fi

# ── Filesystems ───────────────────────────────────────────────────────────────
grep -q 'btrfs' /proc/filesystems \
    && ok "filesystem: btrfs registered" \
    || fail "filesystem: btrfs not registered"

# exFAT may be a module on the current kernel; on localconfig it is built-in.
if grep -q 'exfat' /proc/filesystems; then
    ok "filesystem: exfat registered"
elif modprobe -n exfat &>/dev/null; then
    skip "filesystem: exfat is a module (not yet loaded) — will be built-in on localconfig"
else
    fail "filesystem: exfat not available"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n'
if [[ $_fails -eq 0 ]]; then
    printf 'PASS: all hardware checks passed (%s)\n' "$KVER"
else
    printf 'FAIL: %d check(s) failed (%s)\n' "$_fails" "$KVER"
fi
[[ $_fails -eq 0 ]] || exit 1
