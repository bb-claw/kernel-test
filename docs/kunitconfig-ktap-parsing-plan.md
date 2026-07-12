# kunitconfig KTAP parsing fix — Plan

Branch: `fix/kunitconfig-ktap-parsing`
Start date: 2026-07-12

---

## Situation

`kunitconfig` boot results always show `tests 21/21` but never `kunit:N/N`.
`vm.status` contains `KUNIT_PASS=0 KUNIT_FAIL=0` despite 259 KUnit `ok`/`not ok`
lines being present in the dmesg.

---

## Problems to Solve

1. **ANSI color codes break the grep** — the kernel emits each KUnit line prefixed
   with `\e[32m` (green) and suffixed with `\e[0m` (reset) around the timestamp.
   The pattern `^\[[ 0-9.]+\]` never matches because lines start with `\e[32m[`.

2. **`{4,}` indentation assumption is wrong** — the regex requires 4+ spaces between
   the timestamp `]` and `ok` to distinguish test cases from suite summaries.
   The kernel's printk flattens KTAP hierarchy: every `ok`/`not ok` line is a bare
   printk with no indentation preserved in dmesg. After stripping ANSI codes, all
   `ok` lines look like `[    0.537170] ok 1 test_name` — zero leading spaces.

---

## Goals

1. `kunitconfig` boot shows `kunit:N/N` in the terminal and report.
2. `KUNIT_PASS` / `KUNIT_FAIL` in `vm.status` reflect the actual KUnit results.
3. A KUnit test failure sets `KUNIT_FAIL > 0` and causes `OVERALL=FAIL`.

---

## Scope

Files changed:
- `lib/vm.sh` — strip ANSI codes and `\r` before KUnit parsing; remove `{4,}`

No changes to: test scripts, Makefile, hooks, config files, report.sh.

---

## Non-goals

- Exact exclusion of suite summary lines — suite summaries are few (15 out of 259)
  and correctly mirror test pass/fail state. Including them inflates the count
  slightly but keeps `kunit:N/N` accurate as a pass/fail signal. The Notes column
  shows individual test failures from the init markers, not from KUnit.
- Stripping ANSI codes from the raw dmesg file on disk — the file is kept as-is
  for faithful reproduction of what the kernel emitted; stripping happens only in
  the counting pipeline.

---

## Design decisions

### Strip in pipeline, not in file

`sed 's/\x1b\[[0-9;]*m//g; s/\r//'` is piped into `grep -cE` for each count.
The raw dmesg file is preserved unchanged for debugging and faithful reproduction.

### Remove `{4,}` entirely

After stripping ANSI, there are no indented `ok` lines. The `{4,}` requirement
was designed to filter out suite summaries, but the kernel doesn't emit indented
KTAP lines in dmesg. Removing it lets the regex match all `ok`/`not ok` lines.

Suite summaries are a small fraction (15/259 in the example run) and always
reflect the pass/fail state of their constituent tests, so including them does
not affect correctness of `KUNIT_FAIL`.

### Detection grep unchanged

`grep -qE 'KTAP version|# Subtest:'` does not anchor to line start and matches
even with ANSI codes present (searches for substring). No change needed.

---

## Testing strategy

- **Happy path** — `make all NO_FETCH=1 NO_BUILD=1 CONFIGS=kunitconfig ARCHS="x86_64 i386"`;
  expect `kunit:N/N` in terminal output and `KUNIT_PASS > 0` in `vm.status`.
- **Non-kunit configs unchanged** — `tinyconfig` / `localconfig` must still show
  `tests 21/21` with no `kunit:` column.

---

## Testing commands

```sh
# 1. Verify KUnit counts appear
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=kunitconfig ARCHS="x86_64 i386"
# Expected: "boot OK, tests 21/21, kunit N/N" for both arches

# 2. Check vm.status directly
grep KUNIT build/kunitconfig-x86_64/vm.status
# Expected: KUNIT_PASS=<non-zero> KUNIT_FAIL=0

# 3. Non-kunit configs unchanged
make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS="x86_64 i386"
# Expected: "boot OK, tests 21/21" — no kunit column
```
