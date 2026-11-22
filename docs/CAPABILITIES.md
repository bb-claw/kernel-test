# Capabilities

A capability (CAP) is a named, verifiable property of the kernel-test harness.
Every capability must have a bidirectional link: story §9 → here → acceptance test.

`make verify-traceability` enforces:
- Every CAP id referenced in a story §9 exists here.
- Every CAP here has a non-empty `Covered by` pointer to an existing test file.

## Format

```
### cap.area.name

One-line description of what this capability guarantees.

- **Delivered by**: KT-NNN (story slug)
- **Covered by**: `tests/ci/test_KT_NNN_<slug>.sh`
```

## Registry

<!-- Add capabilities below. Keep sorted by cap id. -->
<!-- Example entry (remove this comment and copy the Format block above):  -->
<!--                                                                        -->
<!-- ### cap.install.fast-copy                                              -->
<!-- bzImage-only copy to /boot without mkinitcpio/grub-mkconfig.          -->
<!-- - **Delivered by**: KT-001                                             -->
<!-- - **Covered by**: `tests/ci/test-install-fast.sh`                     -->
