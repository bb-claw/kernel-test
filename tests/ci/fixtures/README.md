# tests/ci/fixtures/

Static test data used by the `tests/ci/test-*.sh` suite.  Nothing here is
executed directly; the CI tests read these files as inputs to the scripts
they exercise.

## Layout

```
fixtures/
├── parser/                     Serial transcript files for test-vm-parser.sh
│   ├── transcript-pass.txt     Clean boot: BOOT_OK + all TEST PASS + TEST_DONE
│   ├── transcript-panic.txt    Kernel panic before TEST_DONE
│   ├── transcript-timeout-qemu.txt   Empty (QEMU killed before output)
│   ├── transcript-timeout-board.txt  Partial output (real hardware timeout)
│   ├── transcript-ktap.txt     KTAP version block with ok/not ok lines (KUnit)
│   ├── transcript-ktap-notimestamp.txt  KTAP without CONFIG_PRINTK_TIME timestamps
│   └── transcript-canary.txt   CANARY_EARLY marker present
│
├── board/                      Hardware board transcripts for test-board-serial.sh
│   ├── transcript-pass.txt     U-Boot + full pass + KTAP block + TEST_DONE
│   ├── transcript-panic.txt    Kernel panic before BOOT_OK
│   ├── transcript-boot-hang.txt  BOOT_OK reached but no TEST_DONE (mid-test hang)
│   └── transcript-uboot-hang.txt  U-Boot TFTP error, kernel never loads
│
├── reports/                    Fake report directories for test-diff.sh / test-report.sh
│   ├── mainline-7.2-2026-01-01_10-00-00-v7.2-rc1/
│   └── mainline-7.2-2026-01-02_10-00-00-v7.2-rc2/
│
├── archived-configs/           Fake archived .config files for test-config-archive.sh
│                               and test-config-bisect.sh
│
└── consolidation/              Fake multi-source structure for test-consolidate-index.sh
    ├── hetzner-mainline/archive_failed/
    └── local-mainline/archive_failed/
```

## Naming conventions

- `transcript-*.txt` files mirror the structure of `build/<config>-<arch>/dmesg.txt`
  produced by `lib/vm.sh` during a real QEMU boot
- `vmstatus-*.txt` files inside report dirs mirror the structure of
  `build/<config>-<arch>/vm.status`

## Adding fixtures

Add fixture files alongside the test that uses them.  Keep them minimal — only
include the lines the test actually exercises, not a full real-world transcript.
