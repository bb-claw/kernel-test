#!/bin/bash
# CI test for lib/hw-bootstrap.sh and make hw-bootstrap (Phase 6a).
# No hardware, no root, no network required — uses DRY_RUN=1 throughout.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/ci/lib.sh
. "$REPO/tests/ci/lib.sh"

HW_BOOTSTRAP="$REPO/lib/hw-bootstrap.sh"
BOARD_SH="$REPO/lib/board.sh"

# ── 1. Script presence and executable bit ─────────────────────────────────────

begin_test "hw-bootstrap-executable"
assert_file_exists "$HW_BOOTSTRAP" "lib/hw-bootstrap.sh present"
if [[ -x "$HW_BOOTSTRAP" ]]; then pass "lib/hw-bootstrap.sh executable"
else fail "lib/hw-bootstrap.sh not executable"; fi

# ── 2. DRY_RUN=1: atftpd service contains expected fields ────────────────────

begin_test "hw-bootstrap-dryrun-atftpd"
tmpdir
out=$(DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth0" "10.0.0.1" "10.0.0.100,10.0.0.200" "1a86" "7523" 2>&1)
assert_contains "$out" "kernel-test-atftpd.service"  "atftpd: service unit written"
assert_contains "$out" "atftpd"                       "atftpd: binary in ExecStart"
assert_contains "$out" "Type=simple"                  "atftpd: Type=simple"
assert_not_contains "$out" "User="                    "atftpd: no systemd User= directive (drops via --user flag)"
assert_contains "$out" "--bind-address 10.0.0.1"      "atftpd: bound to HW_HOST_IP"
assert_contains "$out" "--user"                        "atftpd: drops to caller via --user flag"

# ── 3. DRY_RUN=1: systemd-networkd config with DHCPServer ─────────────────────

begin_test "hw-bootstrap-dryrun-networkd"
tmpdir
out=$(DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth1" "10.1.0.1" "10.1.0.100,10.1.0.200" "1a86" "7523" 2>&1)
assert_contains "$out" "Name=eth1"                   "networkd: interface name"
assert_contains "$out" "ConfigureWithoutCarrier=yes" "networkd: configure without carrier (Network section)"
assert_contains "$out" "Address=10.1.0.1/24"         "networkd: static IP"
assert_not_contains "$out" "[Link]"                  "networkd: no [Link] section (ConfigureWithoutCarrier belongs in [Network])"
assert_contains "$out" "DHCPServer=yes"              "networkd: built-in DHCP server enabled"
assert_contains "$out" "BootServerAddress=10.1.0.1"  "networkd: DHCP next-server (option 66)"
assert_contains "$out" "BootFilename=Image"           "networkd: DHCP boot filename (option 67)"
assert_contains "$out" "PoolOffset=100"               "networkd: DHCP pool offset from range start"

# ── 4. DRY_RUN=1: NetworkManager unmanaged rule ──────────────────────────────

begin_test "hw-bootstrap-dryrun-nm-unmanaged"
tmpdir
out=$(DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth2" "10.2.0.1" "10.2.0.100,10.2.0.200" "1a86" "7523" 2>&1)
# NM step is always shown (either the conf content or "not active")
assert_contains "$out" "NetworkManager" "NM unmanaged: step shown"
# If NM is active on this host, verify the unmanaged-devices entry
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    assert_contains "$out" "unmanaged-devices=interface-name:eth2" "NM unmanaged: interface entry"
fi

# ── 6. DRY_RUN=1: udev rule contains VID/PID and symlink ─────────────────────

begin_test "hw-bootstrap-dryrun-udev"
tmpdir
out=$(DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth0" "10.0.0.1" "10.0.0.100,10.0.0.200" "dead" "beef" 2>&1)
assert_contains "$out" 'SUBSYSTEM=="tty"'     "udev: subsystem filter"
assert_contains "$out" 'idVendor}=="dead"'   "udev: vendor ID"
assert_contains "$out" 'idProduct}=="beef"'  "udev: product ID"
assert_contains "$out" 'SYMLINK+="vf2-relay"' "udev: stable symlink"
# Group is "dialout" on Debian/Fedora, "uucp" on Arch — check either
if getent group dialout &>/dev/null; then
    assert_contains "$out" 'GROUP="dialout"' "udev: dialout group"
else
    assert_contains "$out" 'GROUP="uucp"'    "udev: uucp group (Arch)"
fi
assert_contains "$out" 'MODE="0664"'          "udev: mode bits"

# ── 7. DRY_RUN=1: TFTP dir not created ────────────────────────────────────────

begin_test "hw-bootstrap-dryrun-no-side-effects"
tmpdir
tftp_dir="$_LAST_TMPDIR/tftp-test"
DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$tftp_dir" "eth0" "10.0.0.1" "10.0.0.100,10.0.0.200" "1a86" "7523" >/dev/null 2>&1
if [[ ! -d "$tftp_dir" ]]; then pass "dry-run: TFTP dir not created"
else fail "dry-run: TFTP dir was created (should not be)"; fi

# ── 6. TFTP_DIR default in Makefile ───────────────────────────────────────────

begin_test "tftp-dir-default"
# Direct check: TFTP_DIR must not contain /srv/tftp and must use CURDIR
makefile_line=$(grep 'TFTP_DIR\s*?=' "$REPO/Makefile")
assert_not_contains "$makefile_line" "/srv/tftp" "TFTP_DIR default not /srv/tftp"
assert_contains     "$makefile_line" "CURDIR"     "TFTP_DIR default uses CURDIR"

# ── 7. board_reset missing-relay graceful fallback ────────────────────────────

begin_test "board-reset-missing-relay"
# Extract board_reset via sed (robust to function length changes), source
# common.sh for warn/info, call with a non-existent relay path.
board_reset_output=$(
    HW_RELAY="/dev/vf2-relay-ci-test-nonexistent-$$" \
    bash -c "
        . '$REPO/lib/common.sh'
        $(sed -n '/^board_reset()/,/^}/p' "$BOARD_SH")
        board_reset
    " 2>&1 || true
)
assert_contains "$board_reset_output" "not found" "board_reset warns on missing relay"

# ── 8. board_reset not-writable relay graceful fallback ──────────────────────

begin_test "board-reset-not-writable"
tmpdir
relay_file="$_LAST_TMPDIR/fake-relay"
touch "$relay_file"; chmod 444 "$relay_file"
board_reset_output=$(
    HW_RELAY="$relay_file" bash -c "
        . '$REPO/lib/common.sh'
        $(sed -n '/^board_reset()/,/^}/p' "$BOARD_SH")
        board_reset
    " 2>&1 || true
)
assert_contains "$board_reset_output" "not writable" "board_reset warns on non-writable relay"

# ── 9. board_reset success path ──────────────────────────────────────────────

begin_test "board-reset-success"
tmpdir
relay_file="$_LAST_TMPDIR/fake-relay-writable"
touch "$relay_file"; chmod 644 "$relay_file"
board_reset_output=$(
    HW_RELAY="$relay_file" bash -c "
        . '$REPO/lib/common.sh'
        $(sed -n '/^board_reset()/,/^}/p' "$BOARD_SH")
        board_reset
    " 2>&1 || true
)
assert_contains "$board_reset_output" "relay pulsed" "board_reset: success path"

# ── 10. VID/PID validation rejects uppercase ──────────────────────────────────

begin_test "hw-bootstrap-vid-pid-validation"
tmpdir
# Verify exit non-zero (not just that "1A86" appears in the banner output)
if DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth0" "10.0.0.1" "10.0.0.100,10.0.0.200" "1A86" "7523" \
    >/dev/null 2>&1; then
    fail "validation: uppercase VID should have exited non-zero"
else
    pass "validation: uppercase VID rejected (exited non-zero)"
fi
# Verify error message names the constraint, not just echoes the raw argument
out=$(DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth0" "10.0.0.1" "10.0.0.100,10.0.0.200" "1A86" "7523" 2>&1 || true)
assert_contains "$out" "lowercase hex" "validation: error message mentions lowercase hex"
# Verify PID validation also rejects uppercase
if DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth0" "10.0.0.1" "10.0.0.100,10.0.0.200" "1a86" "75AB" \
    >/dev/null 2>&1; then
    fail "validation: uppercase PID should have exited non-zero"
else
    pass "validation: uppercase PID rejected (exited non-zero)"
fi

# ── 11. board_reset same-device guard ────────────────────────────────────────

begin_test "board-reset-same-device"
tmpdir
same_dev="$_LAST_TMPDIR/fake-uart-relay"
touch "$same_dev"; chmod 644 "$same_dev"
board_reset_output=$(
    HW_RELAY="$same_dev" BOARD_TTY="$same_dev" bash -c "
        . '$REPO/lib/common.sh'
        $(sed -n '/^board_reset()/,/^}/p' "$BOARD_SH")
        board_reset
    " 2>&1 || true
)
assert_contains "$board_reset_output" "same device" "board_reset: skips when relay == BOARD_TTY"

# ── 12. HW_RELAY in Makefile export block ─────────────────────────────────────

begin_test "hw-relay-exported"
# The export line spans two lines via \; grep the block for HW_RELAY presence.
export_block=$(grep -A2 '^export.*TFTP_DIR' "$REPO/Makefile" || true)
assert_contains "$export_block" "HW_RELAY" "HW_RELAY in Makefile export block"

# ── 13. U-Boot version-string grep pattern ────────────────────────────────────

begin_test "board-capture-uboot-pattern"
PATTERN='U-Boot (SPL )?20[0-9]{2}\.'
# Positive: SPL version banner (VF2 primary U-Boot message)
m=$(printf 'U-Boot SPL 2025.01-3 (Apr 08 2025 - 23:07:41 +0000)\n' | grep -E "$PATTERN" || true)
assert_contains "$m" "U-Boot SPL" "pattern: matches SPL version banner"
# Positive: non-SPL version banner (boards without SPL stage)
m=$(printf 'U-Boot 2025.01-3 (Apr 08 2025 - 23:07:41 +0000)\n' | grep -E "$PATTERN" || true)
assert_contains "$m" "U-Boot 2025" "pattern: matches non-SPL version banner"
# Negative: generic U-Boot reference in kernel log
m=$(printf '[    2.345678] U-Boot environment: parsed variables\n' | grep -E "$PATTERN" || true)
assert_not_contains "$m" "environment" "pattern: rejects 'U-Boot environment' in kernel log"
# Negative: U-Boot command string in bootcmd (no version number with dot)
m=$(printf "setenv bootcmd 'dhcp; tftpboot \${kernel_addr_r} Image'\n" | grep -E "$PATTERN" || true)
assert_not_contains "$m" "bootcmd" "pattern: rejects setenv bootcmd line"
# Verify it reports correct line number using the same pipeline as board.sh
tmpdir
dmesg="$_LAST_TMPDIR/dmesg.txt"
printf '%s\n' \
    "some prior content" \
    "U-Boot SPL 2025.01-3 (Apr 08 2025 - 23:07:41 +0000)" \
    "U-Boot 2025.01-3 (Apr 08 2025 - 23:07:41 +0000)" \
    "starting kernel..." > "$dmesg"
uboot_line=$(grep -m 1 -n -E "$PATTERN" "$dmesg" | cut -d: -f1)
assert_eq "$uboot_line" "2" "pattern: -m 1 returns line number 2 (SPL is first match)"

# ── 14. Pre-anchor trim: removes prior run content from dmesg ──────────────────

begin_test "board-capture-pre-anchor-trim"
tmpdir
dmesg="$_LAST_TMPDIR/dmesg.txt"
# Build a capture file simulating two cycles: prior run ends at TEST_DONE line 3,
# then U-Boot appears at line 5, current run produces 3 passes.
printf '%s\n' \
    "< TEST PASS: 001_smoke" \
    "< TEST PASS: 010_check-proc" \
    "TEST_DONE" \
    "garbage-between-cycles" \
    "U-Boot SPL 2025.01-3 (Apr 08 2025)" \
    "U-Boot 2025.01-3 (Apr 08 2025)" \
    "< TEST PASS: 001_smoke" \
    "< TEST PASS: 010_check-proc" \
    "< TEST PASS: 020_check-sysfs" \
    "kernel-test: 3/3 tests passed" \
    "TEST_DONE" > "$dmesg"
UBOOT_LINE=5
# Apply the same trim logic as board.sh
if [[ -n "$UBOOT_LINE" && "$UBOOT_LINE" -gt 1 ]]; then
    tail -n +"$UBOOT_LINE" "$dmesg" > "${dmesg}.trimmed" \
        && mv "${dmesg}.trimmed" "$dmesg"
fi
first_line=$(head -1 "$dmesg")
assert_contains "$first_line" "U-Boot SPL" "trim: file starts at U-Boot line"
pass_count=$(grep -c '^< TEST PASS:' "$dmesg")
assert_eq "$pass_count" "3" "trim: only current run's 3 passes counted (was 5)"
done_count=$(grep -c 'TEST_DONE' "$dmesg")
assert_eq "$done_count" "1" "trim: prior TEST_DONE removed, only current run's remains"
# Edge case: UBOOT_LINE=1 — no trim should happen
printf '%s\n' \
    "U-Boot SPL 2025.01-3" \
    "< TEST PASS: 001_smoke" \
    "TEST_DONE" > "$dmesg"
original_lines=$(wc -l < "$dmesg")
UBOOT_LINE=1
if [[ -n "$UBOOT_LINE" && "$UBOOT_LINE" -gt 1 ]]; then
    tail -n +"$UBOOT_LINE" "$dmesg" > "${dmesg}.trimmed" \
        && mv "${dmesg}.trimmed" "$dmesg"
fi
trimmed_lines=$(wc -l < "$dmesg")
assert_eq "$trimmed_lines" "$original_lines" "trim: UBOOT_LINE=1 leaves file unchanged"

# ── 15. initramfs.sh init script: board-side summary and counters ─────────────

begin_test "initramfs-board-summary"
assert_contains "$(grep 'pass_count=0'          "$REPO/lib/initramfs.sh")" "pass_count=0" \
    "init: pass_count initialized to 0"
assert_contains "$(grep 'fail_count=0'          "$REPO/lib/initramfs.sh")" "fail_count=0" \
    "init: fail_count initialized to 0"
assert_contains "$(grep 'pass_count=' "$REPO/lib/initramfs.sh" | grep '+ 1')" "pass_count" \
    "init: pass_count incremented on PASS"
assert_contains "$(grep 'fail_count=' "$REPO/lib/initramfs.sh" | grep '+ 1')" "fail_count" \
    "init: fail_count incremented on FAIL"
assert_contains "$(grep 'kernel-test:'           "$REPO/lib/initramfs.sh")" "kernel-test:" \
    "init: board-side summary line present"
assert_contains "$(grep 'kernel-test:'           "$REPO/lib/initramfs.sh")" 'pass_count' \
    "init: summary references pass_count"
assert_contains "$(grep 'sleep 5'                "$REPO/lib/initramfs.sh")" "sleep 5" \
    "init: 5s drain sleep before reboot"
# Verify ordering: summary must appear before TEST_DONE in the template
summary_line=$(grep -n 'kernel-test:' "$REPO/lib/initramfs.sh" | head -1 | cut -d: -f1)
testdone_line=$(grep -n '"TEST_DONE"' "$REPO/lib/initramfs.sh" | head -1 | cut -d: -f1)
if [[ -n "$summary_line" && -n "$testdone_line" && "$summary_line" -lt "$testdone_line" ]]; then
    pass "init: summary line appears before TEST_DONE"
else
    fail "init: summary must appear before TEST_DONE (summary=$summary_line, TEST_DONE=$testdone_line)"
fi

# ── 16. initramfs.sh: /etc/passwd and /etc/group written ─────────────────────

begin_test "initramfs-etc-passwd"
assert_contains "$(grep 'etc/passwd' "$REPO/lib/initramfs.sh")" "etc/passwd" \
    "initramfs: /etc/passwd write present"
assert_contains "$(grep 'etc/group'  "$REPO/lib/initramfs.sh")" "etc/group" \
    "initramfs: /etc/group write present"
assert_contains "$(grep 'etc/passwd' "$REPO/lib/initramfs.sh")" "root:x:0:0" \
    "initramfs: /etc/passwd root entry has correct format"
# mkdir must include 'etc' and 'root' dirs
mkdir_line=$(grep 'mkdir -p' "$REPO/lib/initramfs.sh" | grep STAGE)
assert_contains "$mkdir_line" "etc"  "initramfs: mkdir includes etc"
assert_contains "$mkdir_line" "root" "initramfs: mkdir includes root"

# ── 17. initramfs.sh init script: test-count start message ───────────────────

begin_test "initramfs-start-count"
assert_contains "$(grep 'test_count' "$REPO/lib/initramfs.sh")" "test_count" \
    "init: test_count variable present"
assert_contains "$(grep 'kernel-test: starting' "$REPO/lib/initramfs.sh")" "starting" \
    "init: 'kernel-test: starting' message present"
assert_contains "$(grep 'kernel-test: starting' "$REPO/lib/initramfs.sh")" "test_count" \
    "init: start message references test_count"
# start message must appear before the test loop (pass_count=0)
start_line=$(grep -n 'kernel-test: starting' "$REPO/lib/initramfs.sh" | head -1 | cut -d: -f1)
loop_line=$(grep -n 'pass_count=0' "$REPO/lib/initramfs.sh" | head -1 | cut -d: -f1)
if [[ -n "$start_line" && -n "$loop_line" && "$start_line" -lt "$loop_line" ]]; then
    pass "init: start message appears before test loop"
else
    fail "init: start message must appear before test loop (start=$start_line, loop=$loop_line)"
fi

# ── 18. board.sh: TFTP/PXE progress and failure detection patterns ────────────

begin_test "board-tftp-progress"
# Verify board.sh Phase 1 monitoring uses MONITOR_LINE
assert_contains "$(grep 'MONITOR_LINE' "$REPO/lib/board.sh")" "MONITOR_LINE" \
    "board.sh: MONITOR_LINE tracking present"
# Positive: TFTP progress lines should match info pattern
TFTP_PAT="TFTP from server|Filename '|Bytes transferred|DHCP client bound|PXE:"
m=$(printf 'TFTP from server 192.168.100.1; our IP address is 192.168.100.107\n' \
    | grep -E "$TFTP_PAT" || true)
assert_contains "$m" "TFTP from server" "tftp-pattern: matches TFTP start line"
m=$(printf "Filename 'vf2/Image'.\n" | grep -E "$TFTP_PAT" || true)
assert_contains "$m" "Filename" "tftp-pattern: matches Filename line"
m=$(printf 'Bytes transferred = 24616448 (178c00 hex)\n' | grep -E "$TFTP_PAT" || true)
assert_contains "$m" "Bytes transferred" "tftp-pattern: matches Bytes transferred line"
m=$(printf 'DHCP client bound to address 192.168.100.107 (123 ms)\n' | grep -E "$TFTP_PAT" || true)
assert_contains "$m" "DHCP client bound" "tftp-pattern: matches DHCP bound line"
# Positive: failure lines should match warn pattern
FAIL_PAT='Retry count exceeded|Aborting!|No FDT'
m=$(printf 'Retry count exceeded, starting again\n' | grep -E "$FAIL_PAT" || true)
assert_contains "$m" "Retry count exceeded" "tftp-fail-pattern: matches retry failure"
m=$(printf 'Aborting!\n' | grep -E "$FAIL_PAT" || true)
assert_contains "$m" "Aborting!" "tftp-fail-pattern: matches abort"
m=$(printf 'No FDT memory address configured.\n' | grep -E "$FAIL_PAT" || true)
assert_contains "$m" "No FDT" "tftp-fail-pattern: matches No FDT"
# Negative: progress bars should not match either pattern
m=$(printf '####################  100%% 11.7 MiB/s\n' | grep -E "$TFTP_PAT" || true)
assert_not_contains "$m" "##" "tftp-pattern: does not match progress bar lines"

# ── 19. board.sh: reboot detection and start-message relay ────────────────────

begin_test "board-reboot-detection"
# Verify Phase 2 variables and guards are present in board.sh
assert_contains "$(grep 'PHASE2_REBOOTS' "$REPO/lib/board.sh")" "PHASE2_REBOOTS" \
    "board.sh: PHASE2_REBOOTS variable present"
assert_contains "$(grep 'ANNOUNCED_START' "$REPO/lib/board.sh")" "ANNOUNCED_START" \
    "board.sh: ANNOUNCED_START variable present"
assert_contains "$(grep 'kernel-test: starting' "$REPO/lib/board.sh")" "kernel-test: starting" \
    "board.sh: relays 'kernel-test: starting' from board"
assert_contains "$(grep 'NEXT_UBOOT' "$REPO/lib/board.sh")" "NEXT_UBOOT" \
    "board.sh: NEXT_UBOOT detection present"
# Guard 1: ANNOUNCED_START=0 required (after tests start, next U-Boot is normal reboot)
assert_contains "$(grep 'ANNOUNCED_START.*-eq 0' "$REPO/lib/board.sh")" "ANNOUNCED_START" \
    "board.sh: re-anchor gated on ANNOUNCED_START=0"
# Guard 2: minimum 50-line threshold (filters SPL→main false positive)
assert_contains "$(grep 'NEXT_UBOOT.*-gt 50' "$REPO/lib/board.sh")" "50" \
    "board.sh: re-anchor requires NEXT_UBOOT > 50 lines"
# stat -L: symlinks are followed so /dev/vf2-relay (symlink) resolves to target device
assert_contains "$(grep 'stat -L' "$REPO/lib/board.sh")" "stat -L" \
    "board.sh: stat -L used for symlink-safe device comparison"

# SPL→main false-positive: second U-Boot < 50 lines away should NOT trigger re-anchor
tmpdir
dmesg="$_LAST_TMPDIR/dmesg.txt"
{   printf '%s\n' "U-Boot SPL 2025.01-3 (Apr 08 2025)"
    printf '%s\n' "DDR version: dc2e84f0."
    printf '%s\n' "Trying to boot from SPI"
    printf '%s\n' "U-Boot 2025.01-3 (Apr 08 2025)"     # main U-Boot, 3 lines after SPL
    printf '%s\n' "BOOT_OK: kernel reached init"
    printf '%s\n' "kernel-test: starting 43 tests"
    printf '%s\n' "< TEST PASS: 001_smoke"
    printf '%s\n' "TEST_DONE"
} > "$dmesg"
UBOOT_LINE=1
NEXT_UBOOT=$(tail -n +"$(( UBOOT_LINE + 1 ))" "$dmesg" \
    | grep -m 1 -n -E 'U-Boot (SPL )?20[0-9]{2}\.' | cut -d: -f1 || true)
assert_eq "$NEXT_UBOOT" "3" "reboot-detection: SPL→main is 3 relative lines"
if [[ -n "$NEXT_UBOOT" && $NEXT_UBOOT -gt 50 ]]; then
    fail "reboot-detection: SPL→main (line 3) incorrectly triggers re-anchor (threshold=50)"
else
    pass "reboot-detection: SPL→main (line 3) correctly ignored by 50-line threshold"
fi

# Genuine reboot: second U-Boot > 50 lines away SHOULD trigger re-anchor
tmpdir
dmesg="$_LAST_TMPDIR/dmesg.txt"
{   printf '%s\n' "U-Boot SPL 2025.01-3 (Apr 08 2025)"
    printf '%s\n' "Aborting! No FDT memory configured"
    # 60 lines of failed boot output
    for _ in $(seq 1 60); do printf '%s\n' "riscv: init..."; done
    printf '%s\n' "U-Boot SPL 2025.01-3 (Apr 08 2025)"   # second boot, 62 lines away
    printf '%s\n' "TFTP from server 192.168.100.1"
    printf '%s\n' "BOOT_OK: kernel reached init"
    printf '%s\n' "kernel-test: starting 43 tests"
    printf '%s\n' "< TEST PASS: 001_smoke"
    printf '%s\n' "TEST_DONE"
} > "$dmesg"
UBOOT_LINE=1
NEXT_UBOOT=$(tail -n +"$(( UBOOT_LINE + 1 ))" "$dmesg" \
    | grep -m 1 -n -E 'U-Boot (SPL )?20[0-9]{2}\.' | cut -d: -f1 || true)
if [[ -n "$NEXT_UBOOT" && $NEXT_UBOOT -gt 50 ]]; then
    pass "reboot-detection: genuine reboot (line ${NEXT_UBOOT} > 50) correctly triggers re-anchor"
else
    fail "reboot-detection: genuine reboot at line ${NEXT_UBOOT:-?} should trigger re-anchor (threshold=50)"
fi
NEW_UBOOT_LINE=$(( UBOOT_LINE + NEXT_UBOOT ))
found=$(tail -n +"$(( NEW_UBOOT_LINE + 1 ))" "$dmesg" | grep -F 'TEST_DONE' || true)
assert_contains "$found" "TEST_DONE" "reboot-detection: TEST_DONE visible after genuine re-anchor"
start=$(tail -n +"$(( NEW_UBOOT_LINE + 1 ))" "$dmesg" | grep -m 1 'kernel-test: starting' || true)
assert_contains "$start" "starting 43 tests" "reboot-detection: start message visible after genuine re-anchor"

finish
