# Bug Findings

Bugs identified during code review on `feat/install-name-by-label` (2026-08-26).
Bugs 1–2 (install.sh) were fixed on that branch. The three below are unresolved.

---

## Finding A — `170_pipe.sh`: elif + leading underscore cause false FAIL on 1 MiB pipe test

**File:** `tests/custom/170_pipe.sh` lines 43–58  
**Severity:** High — produces a false FAIL in defconfig/kunitconfig results

**Root cause:** Two Toybox sh bugs compound:

1. **elif bug** (Toybox 0.8.9): when the `if` condition is true, the `else` body also
   executes. When `/dev/zero` exists, `_large_src=/dev/zero` (if body) then
   `_large_src=` (else body) run in sequence — the variable is cleared.

2. **Leading underscore** (`$_varname`): Toybox parses `"$_large_src"` as `$_`
   (last-arg special var) concatenated with the literal string `large_src`.
   If `$_` is empty, `"$_large_src"` expands to `"large_src"`, which is non-empty,
   so `[ -n "$_large_src" ]` passes. `head -c 1048576 "large_src"` then fails
   (no such file), `wc -c` returns 0, and the test reports:
   `FAIL: pipe data loss: expected 1048576 bytes, got 0`.

**Impact:** On any config with `/dev/zero` (defconfig, kunitconfig, randdefconfig, …)
the 1 MiB pipe test always false-FAILs, polluting those config results.

**Mitigation:**
```sh
# Replace elif+else with nested if/else; rename _large_src → large_src
if [ -e /dev/zero ]; then
    large_src=/dev/zero
else
    if [ -e /dev/urandom ]; then
        large_src=/dev/urandom
    else
        large_src=
    fi
fi
if [ -n "$large_src" ]; then
    bytes=$(head -c 1048576 "$large_src" | wc -c)
    ...
```

**Test:** Run defconfig x86_64 and verify `ok: 1 MiB through pipe intact` (not FAIL).

---

## Finding B — `040_check-devnodes.sh`: elif emits spurious skip output

**File:** `tests/custom/040_check-devnodes.sh` lines 45–56  
**Severity:** Low — no false FAIL, but corrupts test output

**Root cause:** Same Toybox 0.8.9 elif bug. Structure:
```sh
if [ -e /dev/urandom ]; then   # always true
    ...ok or fail...
elif [ -e /dev/random ]; then
    ok "..."
else
    skip "..."                 # also executes when if was true
fi
```
When `/dev/urandom` exists (always), the `else` body (`skip "/dev/urandom and
/dev/random not present"`) executes alongside the normal ok/fail line.

**Impact:** Every run produces a spurious `skip: /dev/urandom and /dev/random not
present` in test output. Does not cause a false FAIL (`skip` does not increment
`fails`), but contaminates output and could confuse automated parsers.

**Mitigation:**
```sh
if [ -e /dev/urandom ]; then
    ...ok or fail...
else
    if [ -e /dev/random ]; then
        ok "/dev/random present (urandom absent)"
    else
        skip "/dev/urandom and /dev/random not present"
    fi
fi
```

**Test:** Run any config x86_64, grep test output for `040_check-devnodes` — verify
exactly one urandom-related line, no spurious skip.

---

## Finding C — `common.sh`: `\r` not stripped from FAILED_TESTS, corrupting vm.status

**File:** `lib/common.sh` line 149  
**Severity:** Medium — corrupts vm.status, terminal output, and HTML reports

**Root cause:** QEMU serial output (`-serial file:`) captures raw TTY bytes. The kernel
console TTY layer has `onlcr` set, converting `\n` → `\r\n`. KUnit pass/fail counting
already strips `\r` with `sed 's/\r//'`, but FAILED_TESTS extraction does not:

```bash
FAILED_TESTS=$(grep '^< TEST FAIL:' "$dmesg_file" 2>/dev/null \
    | sed 's/^< TEST FAIL: //' | tr '\n' ' ' | sed 's/ $//' || true)
```

After `tr '\n' ' '`, each test name retains its trailing `\r`:
`170_pipe\r 040_check-devnodes\r`.

**Impact:**
- `vm.status` contains `FAILED_TESTS=170_pipe\r 040_check-devnodes\r`
- Shell comparisons on test names silently never match
- Terminal output from `warn "  FAIL: $_ft"` has `\r`, overwriting the line start
- HTML report may display garbage characters

**Mitigation:** Add `\r` stripping consistent with KUnit counting:
```bash
FAILED_TESTS=$(grep '^< TEST FAIL:' "$dmesg_file" 2>/dev/null \
    | sed 's/\r//; s/^< TEST FAIL: //' | tr '\n' ' ' | sed 's/ $//' || true)
```

**Test:** Add a `tests/ci/` fixture with a synthetic dmesg.txt containing
`\r\n`-terminated `< TEST FAIL:` lines; assert `parse_serial_output` produces
`FAILED_TESTS` with no `\r` characters.
