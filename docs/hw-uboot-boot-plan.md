# Phase 6b — U-Boot TFTP Boot Plan

Branch: `feat/hw-uboot-boot`
Start date: 2026-08-08

---

## Situation

Phase 6a (merged PR #47) set up host-side infrastructure: DHCP via systemd-networkd
DHCPServer, TFTP via atftpd, USB relay, udev symlink. The board can now get an IP and
the host serves files — but U-Boot has no `bootcmd` configured to use TFTP, and
`hw-test` reused the QEMU `TIMEOUT` (360s default) instead of a hardware-specific value.

---

## Problems to Solve

1. **U-Boot `bootcmd` not set** — Default VF2 U-Boot boot sequence tries SPI→MMC→UEFI,
   all fail ("No FDT memory address configured"), drops to `StarFive #` prompt. DHCP/TFTP
   never attempted.
2. **DTB not served** — `make hw-deploy` copied kernel + initramfs but not the board DTB;
   U-Boot needs `vf2.dtb` in TFTP_DIR to load the device tree.
3. **`TIMEOUT` shared with QEMU** — `hw-test` passed QEMU's `TIMEOUT` (default 360s) to
   `board.sh`; no way to tune hardware timeout independently.

---

## Goals

1. `make hw-deploy` builds the board DTB from the kernel tree and copies it to `TFTP_DIR/vf2.dtb`.
2. `HW_TIMEOUT` (default 120s) controls hardware serial capture, independent of `TIMEOUT`.
3. `make hw-bootstrap` next-steps output shows the exact U-Boot commands to paste.
4. `BOARD_DTB` variable selects the DTB filename; default is VF2 v1.2A; v1.3B users override.

---

## Scope

- `Makefile` — add `HW_TIMEOUT ?= 120`, `BOARD_DTB ?= jh7110-starfive-visionfive-2-v1.2a`;
  update hw-deploy to build (`make dtbs`) and copy DTB; update hw-test to use `HW_TIMEOUT`;
  add both to exports and help text
- `lib/hw-bootstrap.sh` — next-steps output: replace "see docs" placeholder with the exact
  `setenv` / `saveenv` / `reset` commands to paste at StarFive # prompt
- `memory/workflows.md` — add `BOARD_DTB` and `HW_TIMEOUT` rows to the variable table
- `docs/hw-uboot-boot-plan.md` — this file

---

## U-Boot One-Time Setup

Connect a USB-UART to `/dev/ttyUSB0`, open a terminal (`minicom -D /dev/ttyUSB0 -b 115200`
or `screen /dev/ttyUSB0 115200`), then power-cycle or wait for the board to drop to the
prompt after its default boot sequence fails. Paste at `StarFive #`:

```
setenv bootcmd 'dhcp; tftpboot ${kernel_addr_r} Image; tftpboot ${fdt_addr_r} vf2.dtb; tftpboot ${ramdisk_addr_r} initramfs-riscv.cpio.gz; booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}'
saveenv
reset
```

What each step does:
- `dhcp` — acquires IP from systemd-networkd; picks up DHCP option 66 (`BootServerAddress`)
  as `serverip` and option 67 (`BootFilename=Image`) as `bootfile`
- `tftpboot ${kernel_addr_r} Image` — downloads kernel image (~27 MiB) to 0x44000000
- `tftpboot ${fdt_addr_r} vf2.dtb` — downloads board DTB to 0x48000000
- `tftpboot ${ramdisk_addr_r} initramfs-riscv.cpio.gz` — downloads initramfs (~4 MiB);
  `${filesize}` is set by this last tftpboot call
- `booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}` — boots the kernel

This is a one-time operation; `saveenv` persists it to SPI flash.

---

## DTB Build (hw-deploy)

`make dtbs` in the kernel build dir is fast (seconds) since the compiler infrastructure
is already in place after `make build`. hw-deploy runs it automatically when the DTB
is absent or stale. The DTB is always named `vf2.dtb` in TFTP_DIR regardless of the
source filename, so the U-Boot `bootcmd` is stable.

For VF2 v1.3B users: `BOARD_DTB=jh7110-starfive-visionfive-2-v1.3b` in `local.mk`.

---

## HW_TIMEOUT Sizing

| Phase | Typical duration |
|---|---|
| U-Boot init + DHCP + TFTP (Image 27M + DTB 60K + initramfs 4M) | ~25s |
| Kernel decompress + boot to init | ~10s |
| initramfs tests (43 tests) | ~30s |
| Total | ~65s |

Default 120s gives 55s headroom for slow TFTP or busy network. Override with
`HW_TIMEOUT=60` for fast iteration once the system is known-good.
