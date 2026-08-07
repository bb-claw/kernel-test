# tests/hardware/

Verification scripts for real-machine boots of the `localconfig` kernel
(Lenovo IdeaPad — AMD Ryzen 7 5800H).  These run on the physical laptop,
not inside QEMU.

## Usage

Boot the custom kernel built with `make local`, then:

```sh
bash ~/git/kernel-test/tests/hardware/verify.sh
```

Exit 0 = all checks passed.  Exit 1 = one or more failures.

## What `verify.sh` checks

| Check | How |
|---|---|
| Kernel identity | `uname -r` contains `localconfig` |
| dmesg health | No oops / panic / BUG in dmesg |
| NVMe storage | `/dev/nvme*` devices present |
| MT7921 WiFi | `mt7921` in dmesg; `wl*` interface in `ip link` |
| Bluetooth (hci0) | `/sys/class/bluetooth/hci0` present; rfkill entry |
| AMD PMC (S2Idle) | `amd_pmc` in dmesg; `s2idle` in `/sys/power/mem_sleep` |
| K10TEMP (die temp) | hwmon entry with `k10temp` name; temperature readable |
| ideapad-laptop | `ideapad_acpi` driver bound; `conservation_mode` node |
| AES-NI | `aes` present in `/proc/crypto` |
| Filesystems | `btrfs` and `exfat` registered in `/proc/filesystems` |

## Differences from QEMU tests

- Uses `bash`, not Toybox sh — standard Linux tools available
- Reads real hardware: `/sys/class/hwmon`, `/sys/class/bluetooth`, etc.
- `dmesg` may be restricted (`kernel.dmesg_restrict=1`); dmesg-dependent
  checks degrade to `skip` gracefully
- Not run by `make ci-test` or `make test` — manual only
