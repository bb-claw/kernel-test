# dev-test Coverage Map

36 functional decision paths across 6 groups.
Fixed core (C1–C9) guarantees ≥72% coverage (27/36 paths, 26/36 without /proc/config.gz).
dev-test fails if coverage ≤ 70% or any step fails.
Updated whenever a new lib branch, config profile, or CI test is added.

| ID  | Description                                                  | Covering scenario                          | Group       |
|-----|--------------------------------------------------------------|--------------------------------------------|-------------|
| A1  | KVM available → `qemu -enable-kvm` (x86 fast boot)          | tinyconfig/x86_64 smoke (HAS_KVM=yes)      | A-pipeline  |
| A2  | KVM absent → TCG fallback (arm64/riscv always; x86 fallback) | defconfig/arm64 smoke or IS_HETZNER        | A-pipeline  |
| A3  | Build PASS → initramfs built → VM boots → tests run          | tinyconfig/x86_64 smoke                    | A-pipeline  |
| A4  | Build FAIL → vm.status shows FAIL, no boot attempted         | random pool (weight 2)                     | A-pipeline  |
| A5  | Build TIMEOUT (exit 124) → vm.status shows TIMEOUT           | random pool (weight 2)                     | A-pipeline  |
| A6  | BOOT=PASS → test scripts execute sequentially                | tinyconfig/x86_64 smoke                    | A-pipeline  |
| A7  | BOOT=FAIL → TEST_DONE absent, vm.status BOOT=FAIL            | random pool (weight 2)                     | A-pipeline  |
| A8  | NO_BUILD=1 → kernel build skipped, initramfs rebuilt         | tinyconfig/x86_64 smoke (NO_BUILD=1)       | A-pipeline  |
| B1  | Standard config (defconfig/kunit) → arch default + fragment  | defconfig/x86_64 smoke                     | B-config    |
| B2  | tinyconfig base + fragment → minimal bootable kernel          | tinyconfig/x86_64 smoke                    | B-config    |
| B3  | rand500config → tinyconfig + 500 sampled random =y lines     | random pool (weight 2)                     | B-config    |
| B4  | randdefconfig → defconfig + 300 randomly disabled options     | random pool (weight 2)                     | B-config    |
| B5  | localconfig → /proc/config.gz sourced + olddefconfig          | localconfig/x86_64 smoke (HAS_LOCAL)       | B-config    |
| B6  | NS-variant config → base config merged with namespaces.config | random pool (weight 2)                     | B-config    |
| C1  | VM serial parser: TESTS_PASS/TESTS_FAIL from TEST PASS anchors | ci-test: test-vm-parser.sh               | C-ci        |
| C2  | KUnit KTAP: ok N / not ok N lines counted from serial output  | ci-test: test-vm-parser.sh               | C-ci        |
| C3  | Report HTML generation (all config × arch → summary.html)    | ci-test: test-report.sh                    | C-ci        |
| C4  | Diff: PASS→FAIL = regression, FAIL→PASS = fix                 | ci-test: test-diff.sh                      | C-ci        |
| C5  | Snapshot: 27-field validation, ISSUES count, 20-bit taint    | ci-test: test-snapshot.sh                  | C-ci        |
| C6  | C programs: musl-gcc 4-arch build (snapshot/syscall-tests/…) | make -C tests/programs all                 | C-ci        |
| C7  | C programs: musl-clang quality gate (x86_64, -Weverything)   | make -C tests/programs all                 | C-ci        |
| D1  | arm64 TCG boot (cortex-a57, 1 G RAM, 2× TIMEOUT)             | random pool (weight 3)                     | D-crossarch |
| D2  | riscv TCG boot (qemu-system-riscv64 ≥8.x, FPU fragment)      | random pool (weight 3)                     | D-crossarch |
| D3  | i386 KVM/TCG boot — tinyconfig (toybox-i686, 32-bit off_t)   | fixed core via C7                          | D-crossarch |
| D4  | Board: U-Boot SPL Phase 1 + Phase 2 TEST_DONE anchor         | random pool (skip: HAS_BOARD absent)       | D-crossarch |
| D5  | Board: TFTP/PXE boot, kernel + DTB transfer                   | random pool (skip: HAS_BOARD absent)       | D-crossarch |
| D6  | hw-bootstrap: networkd DHCPServer + atftpd + udev relay       | random pool (skip: HAS_BOARD absent)       | D-crossarch |
| D7  | i386 KVM/TCG boot — defconfig (32-bit, full test suite)       | fixed core via C8                          | D-crossarch |
| E1  | verify-patch single mode: build one file/dir across arches    | fixed core via C9 (test-arch-scripts.sh)   | E-devtools  |
| E2  | verify-patch before/after (BASE=): git worktree compare       | fixed core via C9 (test-common.sh)         | E-devtools  |
| E3  | config-bisect: 8-cycle binary search, PINNED_OPTS multi-pass  | fixed core via C9 (test-config-bisect.sh) | E-devtools  |
| E4  | kconfig-check: subsystem dependency sweep, GATE_CFGS, DRY_RUN | fixed core via C9 (test-lint-context.sh)  | E-devtools  |
| E5  | dmesg host analysis: rcu/lockup/oom pattern extraction        | fixed core via C9 (test-makefile-defaults.sh) | E-devtools |
| E6  | Warning analysis: per-combo counts, NEW/FIXED vs prev run     | fixed core via C9 (test-warnings.sh)      | E-devtools  |
| F1  | Mainline rc fetch: git ls-remote --depth=1 for latest rc tag  | fixed core via C9 (test-fetch.sh)         | F-fetch     |
| F2  | Stable release fetch: STABLE_RELEASE=X.Y selects latest tag   | fixed core via C9 (test-ns-configs.sh)    | F-fetch     |
| F3  | Stable-rc branch fetch: branch reset to FETCH_HEAD            | fixed core via C9 (test-ns-scripts.sh)    | F-fetch     |
| F4  | linux-next: make fetch-next (separate clone, no rc tags)      | fixed core via C9 (test-ns-build.sh)      | F-fetch     |
