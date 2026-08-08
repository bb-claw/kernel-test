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
assert_contains "$out" "enable-tftp"             "dnsmasq: enable-tftp"
assert_contains "$out" "tftp-root="              "dnsmasq: tftp-root"
assert_contains "$out" "dhcp-boot=Image,,10.0.0.1" "dnsmasq: dhcp-boot next-server"

# ── 3. DRY_RUN=1: systemd-networkd config correct ─────────────────────────────

begin_test "hw-bootstrap-dryrun-networkd"
tmpdir
out=$(DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth1" "10.1.0.1" "10.1.0.100,10.1.0.200" "1a86" "7523" 2>&1)
assert_contains "$out" "Name=eth1"       "networkd: interface name"
assert_contains "$out" "Address=10.1.0.1/24" "networkd: static IP"

# ── 4. DRY_RUN=1: udev rule contains VID/PID and symlink ─────────────────────

begin_test "hw-bootstrap-dryrun-udev"
tmpdir
out=$(DRY_RUN=1 "$HW_BOOTSTRAP" \
    "$_LAST_TMPDIR/tftp" "eth0" "10.0.0.1" "10.0.0.100,10.0.0.200" "dead" "beef" 2>&1)
assert_contains "$out" 'idVendor}=="dead"'   "udev: vendor ID"
assert_contains "$out" 'idProduct}=="beef"'  "udev: product ID"
assert_contains "$out" 'SYMLINK+="vf2-relay"' "udev: stable symlink"
assert_contains "$out" 'GROUP="dialout"'      "udev: dialout group"

# ── 5. DRY_RUN=1: TFTP dir not created ────────────────────────────────────────

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
tmpdir
fake_build="$_LAST_TMPDIR/build"
mkdir -p "$fake_build/vf2config-riscv"

# Source board.sh functions in isolation — we only need board_reset.
# board.sh uses require_env which checks BUILD_DIR/TIMEOUT; avoid triggering
# the full script by sourcing only up to the function definition.
board_reset_output=$(
    HW_RELAY="/dev/this-device-does-not-exist-$$" \
    bash -c "
        . '$REPO/lib/common.sh'
        $(grep -A 30 'board_reset()' "$BOARD_SH" | head -20)
        board_reset
    " 2>&1 || true
)
assert_contains "$board_reset_output" "not found" "board_reset warns on missing relay"

# ── 8. HW_RELAY in Makefile export block ──────────────────────────────────────

begin_test "hw-relay-exported"
# The export line spans two lines via \; grep the block for HW_RELAY presence.
export_block=$(grep -A2 '^export.*TFTP_DIR' "$REPO/Makefile" || true)
assert_contains "$export_block" "HW_RELAY" "HW_RELAY in Makefile export block"

finish
