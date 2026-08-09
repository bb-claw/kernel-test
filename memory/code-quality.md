# Code Quality

## Git Hooks (activate once with `make hooks` or `make bootstrap`)

`git config core.hooksPath .githooks` enables three hooks:

| Hook | Trigger | Checks |
|---|---|---|
| `pre-commit` | every commit | shellcheck on staged `.sh` files; executable bit on staged `tests/**/*.sh`; guard against staged `build/` `cache/` `reports/` |
| `commit-msg` | every commit | conventional commit format: `<type>[(<scope>)]: <desc>` |
| `pre-push` | every push | shellcheck on all tracked `.sh` files; executable bit on all `tests/**/*.sh`; test-inventory coverage; design doc on `feat/*`/`fix/*` branches; context size (CLAUDE.md ≤ 150 lines, memory/*.md ≤ 150 lines); `awk` ban in VM test scripts |

Skip in emergencies only: `git commit --no-verify` / `git push --no-verify`

---

## Commit Message Format

```
<type>[(<scope>)]: <description>
```

Types: `feat` `fix` `docs` `refactor` `chore` `ci` `test` `style` `perf`

Examples:
- `feat: add 200_my-test.sh`
- `fix(180_timer): skip sleep on Toybox i686`
- `chore(hooks): add commit-msg conventional format check`
- `docs: update branch workflow in CLAUDE.md`

---

## When Creating a Branch

1. Name: `<type>/<kebab-slug>` (e.g. `feat/200-ipc-test`, `fix/190-scheduler-i386`)
2. Create `docs/<slug>-plan.md` from `docs/plan-template.md` — required for `feat/*` and `fix/*` (enforced by pre-push)
3. Open a PR to `main` — never commit directly to `main`
4. **Merge strategy**: always merge commits (never squash or rebase); PR title = merge commit subject; `main` has branch protection (PRs required, force-push disabled)

---

## Shell Style

- `#!/bin/bash` + `set -euo pipefail` on every lib script (`lib/`)
- `#!/bin/sh` on every test script — Toybox sh 0.8.9 (POSIX only)
- Functions: `lowercase_snake_case` · Constants: `UPPER_SNAKE_CASE`
- Quote all expansions: `"$VAR"`, `"${VAR:-default}"`
- No `[[ ]]` in test scripts — use `[ ]` (POSIX sh)
- New fetch scripts must use the shared helpers from `lib/common.sh`:
  `setup_git_array` → `reset_to_fetch_head` → `write_kernel_version` (in that order)

---

## C Program Compilation Baseline (tests/programs/)

Reference: each program's `Makefile` under `tests/programs/`; `docs/programs-quality-plan.md`

```
CFLAGS_COMMON       -std=c11 -O2 -D_DEFAULT_SOURCE -Wno-declaration-after-statement -Wno-implicit-function-declaration
CFLAGS_COMMON_GCC   -Wall -Wextra -Wpedantic -Werror
CFLAGS_COMMON_CLANG -Weverything -Werror -Wno-unknown-warning-option -Wno-disabled-macro-expansion -Wno-unsafe-buffer-usage
```

- **serial-capture (host-only)**: `bin/serial-capture-gcc` (musl-gcc, quality gate) + `bin/serial-capture` (musl-clang, shipped).
- **arena-test / perf-event (cross-compiled)**: `bin/<arch>/<name>` (GCC, 4 arches, shipped) + `bin/x86_64/<name>-clang` (musl-clang, quality gate; Clang cross for arm64/riscv needs sysroot not in bootstrap). `make -C tests/programs` builds all three.
- **musl hard-required**: `make bootstrap` installs `musl` (Arch) / `musl-tools` (Debian); build errors if absent. Clang suppressions: `-Wno-disabled-macro-expansion` — musl `stderr` macro; `-Wno-unsafe-buffer-usage` — pointer arithmetic is bounds-correct.
- **Sign-conversion on `tcflag_t`**: cast explicitly: `tty.c_cflag &= (tcflag_t)~CSTOPB;` — code fix, not a suppression.

---

## Bash Lib Script Pitfalls

- **`${arr[-1]:-}` on empty array with `set -euo pipefail`** → bash evaluates the subscript before applying `:-`; prints `arr: bad array subscript` and `set -e` aborts the script. Triggered when `mapfile -t arr < <(...)` receives no output (e.g. `ls-remote` fails on transient TLS error). Fix: `[[ ${#arr[@]} -gt 0 ]] && VAR=${arr[-1]} || VAR=""`.
- **`printf` with format string starting with `-`** → bash's `printf` builtin tries to parse it as an option; produces `printf: - : invalid option`. Fix: `printf -- '- [ ] ...' args`. Affects any shell lib script (`lib/`, `scripts/`) where the format string is a literal dash-prefixed string (e.g., Markdown list items).

---

## initramfs Construction Requirements (lib/initramfs.sh)

- **`/etc/passwd` + `/etc/group` required on SMP hardware**: Toybox sh calls `getpwuid(0)` in `setup_env()` to populate HOME/USER/SHELL. Without `/etc/passwd` it falls back to a BSS struct; on multi-core RISC-V (VisionFive 2 / JH7110) concurrent subprocesses alias into the same NOFORK TT-union BSS region causing SIGSEGV in ~7 of 43 test scripts. Fix: `printf 'root:x:0:0:root:/root:/bin/sh\n' > "$STAGE/etc/passwd"` and matching `/etc/group` — already in initramfs.sh; do not remove.
- **`dmesg -n 1` at top of `/init`**: Deferred kernel printk messages (mmc probe errors, driver register dumps) are flushed asynchronously to the serial console and can split a `< TEST PASS:` marker mid-write, breaking `parse_serial_output`'s `grep -c '^< TEST PASS:'` anchor (observed: 42/43 instead of 43/43 on VF2). The kernel checks `console_loglevel` at flush time, so setting it to `KERN_EMERG` (1) before any test output prevents all such interleaving. The ring buffer is unaffected — `dmesg` in test scripts still reads all messages.

## Toybox sh 0.8.11+ Breaking Changes (affects all versions ≥ 0.8.11)

- **`sh` is a NOFORK builtin** — `sh script.sh` (bare name) runs the script recursively in the same process via "command recursion", bypassing fork+exec. The inner invocation uses a different output path that does not flush to the serial console. **Fix: always use `/bin/sh script.sh` (full path) in `/init` and in any test that forks a shell subprocess.** `/bin/sh` has a `/` in the path, which forces fork+exec and bypasses the NOFORK optimization.
- **Block-buffered stdout** — default stdout buffer type switched from line-buffered to block-buffered. `printf` output may be lost on process exit if the buffer is not flushed. Resolved naturally when using `/bin/sh` (full path) since fork+exec runs in a separate process and flushes on exit.

---

## Toybox sh 0.8.9 Pitfalls (test scripts)

- **`$_x` leading-underscore vars** → Toybox parses as `$_` + literal; use plain names (`fails`, not `_fails`)
- **`trap`** → not a builtin; use `/bin/kill` for cleanup
- **`kill` builtin** → only `kill -0 $$` works; use `/bin/kill` for all other signals
- **`sleep N` on i386** → Toybox i686 sleep exits non-zero; guard with `if sleep N; then ... else skip ...; fi`
- **`$(( ))` in while loops** → OOM in 512 MB VM; use `for i in 1 2 3 ... 20` instead
- **`while true; do true; done` busyloop** → `true` is a Toybox applet (external cmd); each iteration forks+execs, zombie accumulation fills all guest RAM (485 MiB in 512M, 977 MiB in 1G VM). Use `while :; do :; done` — `:` is a special builtin, no fork per iteration, CPU-bound so signals are delivered in TCG.
- **`sleep N &` target in arm64 QEMU TCG** → blocking `nanosleep` cannot receive signals in TCG mode; `wait $pid` hangs until VM timeout. Use CPU-busy `:` busyloop instead.
- **any `fork()` in arm64 QEMU TCG** → child immediately faults in parent's full COW RSS (~1G anon-rss); OOM-killed; affects `sh -c '...' &`, `( ... ) &` subshell, and exec variants. Fix: detect `aarch64` via `uname -m` and skip tests that need background processes.
- **`elif`** → Toybox sh 0.8.9 bug: specifically when `if...elif...else...fi` is used and the `if` condition is true, both the `if` body and the `else` body execute (double output). `if...elif...fi` with no `else` is safe. Fix: use nested `if/else/fi` inside the `else` branch instead of `elif`.
- **`dd if=FILE bs=N count=N`** → Toybox dd ignores key=value args; use `head -c N` instead
- **`awk`** → not compiled into the prebuilt Toybox 0.8.9 binary; use `grep | cut -f2` for tab-delimited `/proc` files, or `cut -d: -f2` for colon-delimited. Caught by pre-push hook (check 6).
- **`if out=$(cmd); then`** → Toybox sh bug: a variable assignment always exits 0, so the command's real exit code is swallowed and the branch always evaluates as true. Use `cmd > /tmp/out.txt 2>&1` to redirect to a file; check `$?`; read the file for diagnostics.
- **`tr`** → not compiled into the prebuilt Toybox 0.8.9 binary; use `sed 's/old/new/g'` for character substitution or `grep -o` for character filtering.
- **Multi-line string comparison in `[ ]`** → Toybox sh 0.8.9 bug: `[ "$var" = "line1\nline2" ]` returns false even when `$var` is exactly that content. Fix: use `grep -q "^pattern$" file` or compare individual lines instead of comparing a multi-line captured variable against a literal multi-line string.
- **FIFO blocking open with `&`** → `printf 'x' > "$FIFO" &` + `cat "$FIFO"`: both the background writer and the reader block in `open()` waiting for the other end; if the background fork is not scheduled before the reader, both deadlock until VM timeout. Fix: open with `exec 3<>"$FIFO"` (O_RDWR, non-blocking) and close immediately, or use only inode-level tests (mkfifo + `-p`). Do not attempt write+read on the same fd — Toybox sh 0.8.9's `read` builtin ignores `<&N` redirects when reading from a pipe fd, always returning empty.
- **`case "$val" in N*)` numeric glob on arm64/riscv** → pattern like `1*|2*|3*` fails to match numeric strings (e.g. `3884`) on arm64/riscv Toybox sh. Fix: use `[ "$val" -gt 0 ] 2>/dev/null` for positive-integer checks instead of glob patterns.
- **`cmd | grep -q 'pat' \<newline>    && ok || fail`** → Toybox sh bug: `\<newline>` (line continuation) at the end of a command inside a pipeline passes trailing whitespace (the indentation of the next line) as an extra file argument to the last command before the `\`. `grep` receives a space as a filename and exits non-zero, triggering `|| fail` even when the pipeline input matches. Fix: use `if cmd | grep -q 'pat'; then ok; else fail; fi` — avoid `\<newline>` inside pipeline + `&&`/`||` chains entirely.

---

## Test Script Pattern

```sh
#!/bin/sh
fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

[ -r /some/file ] || { skip "prerequisite absent"; exit 0; }
if [ condition ]; then ok "thing works"; else fail "thing broken"; fi
[ $fails -eq 0 ] || exit 1
```

---

## Memory File Update Triggers

| When you… | Update |
|---|---|
| Add a test script | `test-inventory.md` (new row, update next slot) · `project.md` |
| Remove a test script | `test-inventory.md` (remove row) · `project.md` |
| Add/remove a config profile | `config-profiles.md` · `project.md` |
| Change a Makefile variable (name, default, purpose) | `workflows.md` |
| Change build, fetch, or test pipeline behaviour | `workflows.md` · `project.md` |
| Discover a new Toybox sh bug | `code-quality.md` (Toybox pitfalls list) |
| Change a git hook or quality gate | `code-quality.md` (hooks table) |

---

## Review Checklist (before opening a PR)

- [ ] `shellcheck --severity=warning` clean (pre-push does this automatically)
- [ ] All test scripts are executable (`ls -la tests/custom/`)
- [ ] `make all NO_FETCH=1 CONFIGS=tinyconfig ARCHS="x86_64 i386"` passes
- [ ] New test: skip guard present for missing kernel options
- [ ] All error paths in lib scripts write `STATUS=FAIL` before `die`
- [ ] Memory files updated (`memory/test-inventory.md`, `memory/code-quality.md`)
- [ ] Design doc (`docs/<slug>-plan.md`) complete and accurate
