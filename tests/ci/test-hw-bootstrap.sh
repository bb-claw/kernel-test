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

# ── 2. DRY_RUN=1: dnsmasq config contains expected fields ─────────────────────

begin_test "hw-bootstrap-dryrun-dnsmasq"
tmpdir
out=$(DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth0" "10.0.0.1" "10.0.0.100,10.0.0.200" "1a86" "7523" 2>&1)
assert_contains "$out" "interface=eth0"          "dnsmasq: interface field"
assert_contains "$out" "bind-interfaces"         "dnsmasq: bind-interfaces"
assert_contains "$out" "10.0.0.100,10.0.0.200"  "dnsmasq: dhcp-range"
assert_contains "$out" "dhcp-leasefile="         "dnsmasq: lease file in TFTP_DIR"
assert_contains "$out" "enable-tftp"             "dnsmasq: enable-tftp"
assert_contains "$out" "tftp-root="              "dnsmasq: tftp-root"
assert_contains "$out" "dhcp-boot=Image,,10.0.0.1" "dnsmasq: dhcp-boot next-server"
# conf-dir step: either already enabled or dry-run says it would append
assert_contains "$out" "conf-dir"                    "dnsmasq: conf.d inclusion handled"
assert_contains "$out" "dnsmasq.service.d"           "dnsmasq: systemd drop-in path"
assert_contains "$out" "User=$(id -un)"              "dnsmasq: systemd drop-in User= set to caller"
assert_contains "$out" "ProtectHome=no"              "dnsmasq: systemd drop-in clears ProtectHome"
assert_contains "$out" "ProtectSystem=no"            "dnsmasq: systemd drop-in clears ProtectSystem"

# ── 3. DRY_RUN=1: systemd-networkd config correct ─────────────────────────────

begin_test "hw-bootstrap-dryrun-networkd"
tmpdir
out=$(DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth1" "10.1.0.1" "10.1.0.100,10.1.0.200" "1a86" "7523" 2>&1)
assert_contains "$out" "Name=eth1"                   "networkd: interface name"
assert_contains "$out" "ConfigureWithoutCarrier=yes" "networkd: configure without carrier (Network section)"
assert_contains "$out" "Address=10.1.0.1/24"         "networkd: static IP"
assert_not_contains "$out" "[Link]"                  "networkd: no [Link] section (ConfigureWithoutCarrier belongs in [Network])"

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

# ── 11. HW_RELAY in Makefile export block ─────────────────────────────────────

begin_test "hw-relay-exported"
# The export line spans two lines via \; grep the block for HW_RELAY presence.
export_block=$(grep -A2 '^export.*TFTP_DIR' "$REPO/Makefile" || true)
assert_contains "$export_block" "HW_RELAY" "HW_RELAY in Makefile export block"

finish
