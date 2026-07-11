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

# ── dmesg health ──────────────────────────────────────────────────────────────
if dmesg | grep -qiE 'oops:|kernel panic|BUG: (unable|bad|spinlock|scheduling)'; then
    fail "dmesg: oops/panic/BUG detected"
    dmesg | grep -iE 'oops:|kernel panic|BUG: ' | head -3 | \
        while IFS= read -r line; do printf '  %s\n' "$line"; done
else
    ok "dmesg: no oops/panic/BUG"
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
if dmesg | grep -qi 'mt7921'; then
    ok "MT7921: driver loaded (dmesg)"
else
    fail "MT7921: not found in dmesg"
fi

WIFI_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep '^wl' | head -1)
if [[ -n $WIFI_IF ]]; then
    ok "WiFi interface: $WIFI_IF"
else
    fail "WiFi: no wl* interface found"
fi

# ── Bluetooth ─────────────────────────────────────────────────────────────────
if dmesg | grep -qi 'btmtk\|btusb.*mediatek\|bluetooth.*mediatek'; then
    ok "Bluetooth: btmtk/MediaTek driver in dmesg"
else
    fail "Bluetooth: btmtk not found in dmesg"
fi

if command -v rfkill &>/dev/null; then
    rfkill list 2>/dev/null | grep -qi bluetooth \
        && ok "Bluetooth: rfkill entry present" \
        || fail "Bluetooth: not found in rfkill list"
else
    skip "Bluetooth rfkill: rfkill not installed"
fi

# ── AMD PMC (S2Idle suspend) ──────────────────────────────────────────────────
if dmesg | grep -qiE 'amd.pmc|amd_pmc'; then
    ok "AMD PMC: driver loaded"
else
    fail "AMD PMC: not found in dmesg"
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
if dmesg | grep -qi 'ideapad'; then
    ok "ideapad-laptop: driver loaded"
else
    fail "ideapad-laptop: not found in dmesg"
fi

CONS=$(ls /sys/bus/platform/devices/*/conservation_mode 2>/dev/null | head -1)
if [[ -n $CONS ]]; then
    ok "ideapad-laptop: conservation_mode node at $CONS"
else
    skip "ideapad-laptop: conservation_mode node absent (may require specific ACPI firmware)"
fi

# ── AES-NI ────────────────────────────────────────────────────────────────────
if grep -q $'^name\t*:.*aes' /proc/crypto 2>/dev/null; then
    ok "AES-NI: aes present in /proc/crypto"
else
    fail "AES-NI: not found in /proc/crypto"
fi

# ── Filesystems ───────────────────────────────────────────────────────────────
grep -q 'btrfs' /proc/filesystems \
    && ok "filesystem: btrfs registered" \
    || fail "filesystem: btrfs not registered"

grep -q 'exfat' /proc/filesystems \
    && ok "filesystem: exfat registered" \
    || fail "filesystem: exfat not registered"

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n'
if [[ $_fails -eq 0 ]]; then
    printf 'PASS: all hardware checks passed (%s)\n' "$KVER"
else
    printf 'FAIL: %d check(s) failed (%s)\n' "$_fails" "$KVER"
fi
[[ $_fails -eq 0 ]] || exit 1
