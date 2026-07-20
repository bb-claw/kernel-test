# Boot Safety Checks — Plan

Branch: `feat/boot-safety-checks`
Start date: 2026-07-19

---

## Situation

The harness has twice produced silent boot failures where a bootable kernel config was
missing mandatory options (`CONFIG_PRINTK`, `CONFIG_TTY`, `CONFIG_BLK_DEV_INITRD`,
`CONFIG_BINFMT_ELF`, `CONFIG_BINFMT_SCRIPT`, `CONFIG_TMPFS`). In both cases, `olddefconfig`
silently dropped options from the applied fragment — leaving a config that can build but
can never boot. The result is a 60-second QEMU timeout or a clean QEMU exit 0 with zero
dmesg output, both of which are hard to distinguish from real regressions.

---

## Problems to Solve

1. **Silent unbootable builds** — `olddefconfig` can drop fragment-supplied bootability
   options (e.g. when an option's dependency chain changes between kernel versions). The
   harness detects the failure only at boot time, after spending the full build time.

2. **Misclassified BOOT_FAIL label** — when QEMU exits 0 but dmesg is empty (no console
   output at all), the current code labels it `Did not reach init (QEMU exit 0)` and the
   archive may assign `BOOT_FAIL-timeout`. The actual symptom — no console — is not
   captured, making the failed config entry in the archive misleading.

---

## Goals

1. After the fragment step in `build.sh`, verify all bootability options from
   `configs/tinyconfig.config` are present in the final `.config` for every bootable
   config; auto-correct missing ones; die if correction fails.
2. Record `CONFIG_CORRECTED=1` in `build.status` and surface `cfg-fixed` in the report
   Notes column when auto-correction fires.
3. In `vm.sh`, detect QEMU exit 0 with empty dmesg and set `FAIL_REASON=BOOT_FAIL-no-console`
   instead of the generic exit-0 message.
4. In `config-archive.sh`, add a `BOOT_FAIL-no-console` detail case that returns the
   fixed string `no console output`.

---

## Scope

Files changed:
- `lib/build.sh` — add bootability check + auto-correction step after step 1b
- `lib/vm.sh` — narrow the QEMU exit 0 branch to detect empty dmesg
- `lib/report.sh` — read `CONFIG_CORRECTED=1` and append `cfg-fixed` to Notes
- `scripts/config-archive.sh` — add `BOOT_FAIL-no-console` case in `get_fail_detail()`

No changes to: `configs/tinyconfig.config` (used as-is as the authoritative source),
`Makefile`, test scripts, memory files (no new test scripts or config profiles).

---

## Non-goals

- Detecting corrections in the HTML `title=` tooltip (plain text Notes is sufficient).
- A retry loop: one correction pass only; die on second failure.
- Surfacing `BOOT_FAIL-no-console` differently in the HTML vs text report (same Notes
  column treatment as other BOOT_FAIL variants).

---

## Design decisions

### Authoritative source for mandatory options

`configs/tinyconfig.config` is used as the bootability baseline for **all** bootable
configs, not just tinyconfig runs. It already contains exactly the minimum set of options
required to boot any config in the harness (PRINTK, TTY + arch serial, initramfs,
BINFMT_ELF/SCRIPT, TMPFS). Using it as a shared floor avoids hardcoding a list in
`build.sh` and stays in sync automatically when the fragment is updated.

Alternative considered: per-config fragment as the source. Rejected because defconfig and
kunitconfig have no fragment, yet should still have PRINTK/TTY checked.

### Correction mechanism

Append only the **missing** options (not the full fragment) to `.config`, then re-run
`olddefconfig`. This is the same mechanism as the original fragment step and is
well-understood. Appending only the missing options avoids overwriting options that the
config's own fragment has legitimately set differently.

Extract missing options by comparing `grep '^CONFIG_[A-Z0-9_]*=y' configs/tinyconfig.config`
against the final `.config`.

### Correction failure behaviour

If after the correction pass an option is still not set (unsatisfiable dependency in this
kernel version), `die` with a message listing the outstanding options. This prevents a
silent unbootable build and makes the regression immediately visible. A warn-and-continue
approach would waste build time and produce a confusing report.

### CONFIG_CORRECTED in build.status

Binary flag `CONFIG_CORRECTED=1`. The WARN line in the build log already records which
specific options were corrected; the flag in `build.status` is only needed for
`report.sh` to surface `cfg-fixed` in the Notes column. A list of option names in
`build.status` would add parsing complexity for no additional value in the report.

### Check scope

All bootable configs (`! is_build_only`). Even configs that have a strong fragment
(rand500config, randdefconfig, kunitconfig) are checked, because the correction is
a no-op when no options are missing — cost is two `grep` calls.

### BOOT_FAIL-no-console detection

Condition: QEMU exit code 0 **and** dmesg file is empty (0 bytes via `[[ ! -s "$DMESG" ]]`).
This is the narrowest correct signal: a clean exit with zero output means the kernel ran
(did not crash), but produced nothing on the serial console — the no-console case.
Other QEMU exit-0 cases (non-zero dmesg but no `/proc/version` marker) continue through
the existing logic unchanged.

---

## Testing strategy

- **#1 build.sh correction** — replay a known-bad archived config (the v7.2-rc3
  tinyconfig-arm64 that had CONFIG_PRINTK=n) via `make replay` and confirm the WARN
  line and `CONFIG_CORRECTED=1` appear; confirm the kernel actually boots.
- **#2 vm.sh no-console** — run `make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS=arm64`
  with a kernel that strips PRINTK (manual test or the archived bad config) and confirm
  `BOOT_FAIL-no-console` appears in `vmstatus-*.txt` and the archive filename.
- **Regression** — run `make smoke` on a clean kernel and confirm no false positives
  (no spurious `cfg-fixed` notes, no spurious `BOOT_FAIL-no-console`).

---

## Testing commands

```sh
# 1. Verify correction fires on the known-bad archived config
make replay CONFIG_FILE=configs/archive_failed/kconfig-tinyconfig-arm64-v7.2-rc3-46a56cade2f4f4e7697999850e8b9072adb3cf5b275bbe2aa9b0d090f2135034-BOOT_FAIL-timeout.config
# Expected: WARN line listing corrected options; CONFIG_CORRECTED=1 in build/tinyconfig-arm64/build.status

# 2. Smoke run — no false positives
make smoke NO_FETCH=1
# Expected: no cfg-fixed notes; no BOOT_FAIL-no-console in any vmstatus

# 3. Confirm no-console label in archive after config-archive run
make config-archive
# Expected: BOOT_FAIL-no-console suffix on any config that triggered empty-dmesg+exit-0
```
