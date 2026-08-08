# Hardware Bootstrap (Phase 6a) — Plan

Branch: `feat/hw-bootstrap`
Start date: 2026-08-08

---

## Situation

Phase 5 (PR #45) added `lib/board.sh`, `make hw-deploy/hw-test/hw/hw-full`, and the
`serial-capture` C binary for USB-UART capture.  The `board_reset` function is a stub
(warns + requires manual power-cycle), and `TFTP_DIR` defaulted to `/srv/tftp`.

Phase 6a completes the host-side infrastructure: isolated test network (dnsmasq DHCP+TFTP
on a dedicated Ethernet interface), USB relay reset, and a single `make hw-bootstrap`
target that sets everything up from scratch — without modifying `make bootstrap`, which
runs on QEMU-only machines (Hetzner staging) that have no board hardware.

---

## Problems to Solve

1. **`TFTP_DIR=/srv/tftp`** — hardcoded system path; conflicts with distro TFTP daemons;
   not gitignored; requires root to create.
2. **No host network setup** — TFTP and DHCP must be configured manually; no reproducible
   entrypoint; no isolation from the main LAN DHCP server.
3. **`board_reset` stub** — automated `make hw` pipeline stalls waiting for manual board
   power-cycle.
4. **USB relay needs udev rule** — without it the relay device is root-only and the
   pipeline must run as root.
5. **No CI coverage** — board reset and TFTP deploy have no automated tests.

---

## Goals

1. `TFTP_DIR` defaults to `$(CURDIR)/tftp` (local, gitignored, no root required).
2. `make hw-bootstrap` installs dnsmasq, writes all config files, installs udev rule,
   creates `$(TFTP_DIR)` — fully reproducible, idempotent, needs sudo once.
3. `board_reset` in `lib/board.sh` pulses the USB relay via `HW_RELAY` (CH340 protocol);
   warns gracefully when device absent (manual fallback preserved).
4. CI test (`tests/ci/test-hw-bootstrap.sh`) verifies dry-run output, board_reset
   fallback, and TFTP_DIR default — all without hardware or root.

---

## Scope

- `Makefile` — change `TFTP_DIR` default; add `HW_IFACE`, `HW_HOST_IP`,
  `HW_DHCP_RANGE`, `HW_RELAY`, `HW_RELAY_VID`, `HW_RELAY_PID` variables;
  add `hw-bootstrap` target; update exports + help text
- `lib/hw-bootstrap.sh` — new script: package install, dnsmasq config, systemd-networkd
  config, udev rule, TFTP dir; `DRY_RUN=1` prints actions without writing files
- `lib/board.sh` — replace `board_reset` stub with CH340 relay pulse; keep warn fallback
  when `HW_RELAY` device absent
- `.gitignore` — add `tftp/`
- `tests/ci/test-hw-bootstrap.sh` — new CI test (no hardware, no root)
- `memory/workflows.md` — add new variables to the table

No changes to: `lib/bootstrap.sh`, `lib/vm.sh`, `lib/build.sh`, any test scripts,
`make smoke`/`make extended` pipelines.

---

## Non-goals

- Phase 6b (U-Boot `bootcmd` setup, first live `make hw` run) — requires the board.
- `make hw-bootstrap` does NOT enable `tftpd-hpa`; dnsmasq's built-in TFTP is used.
- No support for non-CH340 relay protocols in this phase; `HW_RELAY_CMD` override deferred.
- No PXE boot support — U-Boot `tftpboot` is sufficient.

---

## New Variables

| Variable | Default | Purpose |
|---|---|---|
| `TFTP_DIR` | `$(CURDIR)/tftp` | Local TFTP root; gitignored; created by hw-deploy |
| `HW_IFACE` | `eno1` | Ethernet interface for the isolated test network |
| `HW_HOST_IP` | `192.168.100.1` | Static IP assigned to `HW_IFACE` by systemd-networkd |
| `HW_DHCP_RANGE` | `192.168.100.100,192.168.100.200` | DHCP pool handed to the board |
| `HW_RELAY` | `/dev/vf2-relay` | Stable symlink to the USB relay (created by udev rule) |
| `HW_RELAY_VID` | `1a86` | USB vendor ID of the relay (CH340 default) |
| `HW_RELAY_PID` | `7523` | USB product ID of the relay (CH340 default) |

Override in `local.mk` for machine-specific values.

---

## U-Boot One-Time Setup (Phase 6b prerequisite — documented here)

After `make hw-bootstrap`, connect to the board via serial and run once:

```
StarFive # setenv bootcmd 'dhcp; tftpboot ${kernel_addr_r} Image; tftpboot ${ramdisk_addr_r} initramfs-riscv.cpio.gz; booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}'
StarFive # saveenv
```

`dhcp` picks up `serverip` from dnsmasq's `dhcp-boot` next-server field automatically.
No manual `setenv serverip` needed as long as `hw-bootstrap` configured the `dhcp-boot`
line in dnsmasq.

---

## CI Strategy

`tests/ci/test-hw-bootstrap.sh` tests without hardware or root:

1. `lib/hw-bootstrap.sh` is executable and shellcheck-clean.
2. `DRY_RUN=1` prints dnsmasq/networkd/udev config blocks to stdout — assert key fields.
3. `board_reset` with missing `HW_RELAY` device emits a warning and exits 0.
4. `TFTP_DIR` default in Makefile is `./tftp`, not `/srv/tftp`.
5. `make hw-deploy` with a fake build dir creates `TFTP_DIR` and prints expected paths.
