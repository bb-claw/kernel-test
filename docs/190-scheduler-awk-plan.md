# 190_scheduler awk fix — Plan

Branch: `fix/190-scheduler-awk`
Start date: 2026-07-12

---

## Situation

`190_scheduler` fails on `localconfig` (both x86_64 and i386) but passes on `tinyconfig`.
Root cause: line 42 calls `awk '{print $2}'` to extract a field from `/proc/self/status`.
`awk` is not compiled into the prebuilt Toybox 0.8.9 binary used in the initramfs.

On tinyconfig the field `voluntary_ctxt_switches` is absent from `/proc/self/status`
(stripped-down kernel), so the `awk` line is never executed — the test skips.
On localconfig (full desktop kernel) the field is present, `awk` is called, and the
shell reports `sh: awk: No such file or directory`, causing the test to FAIL.

---

## Problems to Solve

1. **`awk` in VM test scripts** — not available in Toybox; any call to it silently
   passes on stripped configs (skip path) but fails on full configs (exec path).
2. **No hook catches this** — `awk` usage in test scripts reaches main undetected;
   the tinyconfig smoke run in the PR checklist does not exercise the code path.

---

## Goals

1. `190_scheduler` passes on localconfig (x86_64 and i386) and tinyconfig unchanged.
2. Pre-push hook blocks future `awk` usage in VM test scripts before it can be pushed.
3. `memory/code-quality.md` documents `awk` as a Toybox pitfall.

---

## Scope

Files changed:
- `tests/custom/190_scheduler.sh` — replace `awk '{print $2}'` with `cut -f2`
- `.githooks/pre-push` — add check 6: ban `awk` in `tests/custom/*.sh` and `tests/001_smoke.sh`
- `memory/code-quality.md` — add `awk` to Toybox pitfalls list

No changes to: tinyconfig.config, localconfig.config, any other test script, Makefile.

---

## Non-goals

- Fixing `awk` usage in `tests/hardware/verify.sh` — that script runs on real hardware
  with full system tools, not inside the Toybox initramfs. `awk` is fine there.
- Adding `awk` to the Toybox initramfs — prebuilt binary is pinned; adding it would
  require a custom build and defeats the lean prebuilt approach.

---

## Design decisions

### `cut -f2` vs shell parameter expansion

`/proc/self/status` lines are tab-separated: `field:\t<value>`.
`cut -f2` is the simplest Toybox-available replacement and handles the tab correctly.
Shell parameter expansion (`${line##*:}` + `${val# }`) also works but is noisier.
Chose `cut -f2`.

### Ban `awk` in pre-push vs pre-commit

Pre-push sweeps all tracked files — same pattern as the shellcheck and inventory checks.
Pre-commit only checks staged files (would miss `awk` introduced in an earlier commit).
Added to pre-push (check 6) so the sweep is comprehensive.
`tests/hardware/verify.sh` is explicitly excluded from the ban.

---

## Testing strategy

- **190_scheduler on localconfig** — run `make all NO_FETCH=1 CONFIGS=localconfig ARCHS="x86_64 i386"`; expect PASS.
- **190_scheduler on tinyconfig** — expect existing skip/pass behaviour unchanged.
- **Pre-push hook** — introduce a temporary `awk` call in a test script, verify the hook blocks push; revert.

---

## Testing commands

```sh
# 1. Full run on localconfig to confirm fix
make all NO_FETCH=1 CONFIGS=localconfig ARCHS="x86_64 i386"
# Expected: 21/21 tests PASS on both arches, OVERALL=PASS

# 2. Tinyconfig unchanged
make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS="x86_64 i386"
# Expected: 21/21 PASS (skip lines for ctxt_switches, schedstat unchanged)

# 3. Hook catches awk
echo "val=\$(awk '{print \$1}' /proc/version)" >> tests/custom/190_scheduler.sh
git push origin fix/190-scheduler-awk
# Expected: [pre-push] FAIL: awk used in VM test script
git checkout tests/custom/190_scheduler.sh
```
