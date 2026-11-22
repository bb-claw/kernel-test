# Patch quality and review workflow

Two roles, one document:

- **Author** — quality gate before sending your own patch
- **Reviewer / maintainer** — systematic workflow for verifying patches from others

For authoring mechanics (commit format, send-email, checkpatch) see
`docs/upstream-patch-workflow.md`.

---

## Part A — Pre-send quality gate (your own patches)

Work through every question before running `git send-email`.
A "no" is a blocker — fix it first.

### 1. Problem statement

- [ ] Can you state the bug in one sentence without quoting the error message?
- [ ] Is there a minimal, self-contained reproducer (commands to trigger from scratch)?
- [ ] Is the reproducer documented in the commit message (after `---`)?

If you cannot write the reproducer without looking at the code, you do not yet
understand the bug well enough to fix it.

### 2. Root cause

- [ ] Is the root cause identified, not just the symptom?
- [ ] Does your fix address the root cause — not silence a compiler warning or
  paper over a symptom?
- [ ] Could the fix mask a deeper problem (e.g. zero-init hiding an uninitialized
  read that should not happen at all)?
- [ ] Are there other call sites, structs, or files with the same underlying bug?

A struct-level fix is almost always better than a call-site workaround.
Ask: "would a new call site in the same pattern automatically be safe?"
If not, the fix is in the wrong place.

### 3. Build verification

```sh
make verify-patch FILES=<path/to/file.o> BASE=<current-rc>
```

- [ ] Run with at least `ARCHS="arm64 x86_64"` (two architectures minimum)?
- [ ] Both GCC and Clang tested (`COMPILER=both`, the default)?
- [ ] Tested with `allmodconfig` (the config most likely to expose build-only bugs)?
- [ ] Verdict is `FIXED` (before: N errors → after: PASS) or `UNCHANGED-PASS`?
- [ ] If the affected code has `depends on ARCH_X || COMPILE_TEST`, is
  `CONFIG_COMPILE_TEST=y` set? Without it a non-native arch silently skips
  building the driver — a PASS result means nothing for that combo.
- [ ] No new `: warning:` lines in the after-logs?

```sh
grep ': warning:' build/verify-patch/logs-*/arm64-gcc-after.log
```

### 4. Runtime verification

- [ ] Has the patched kernel actually booted — not just compiled?
- [ ] Tested on the architecture(s) where the bug was observed?
- [ ] `make all NO_FETCH=1 CONFIGS=defconfig ARCHS=<affected-arch>` passes?

Build-only bugs (allmodconfig failures) do not need a boot test.
Runtime bugs and driver changes always do.

### 5. Format and metadata

```sh
git format-patch -1 --stdout | scripts/checkpatch.pl --strict -
git format-patch -1 --stdout | scripts/get_maintainer.pl
```

- [ ] `checkpatch.pl --strict` reports 0 errors, 0 warnings?
- [ ] Commit subject: `subsystem: component: short imperative phrase` (≤72 chars)?
- [ ] `Fixes: <12-hex-sha> ("<original subject>")` present for regression fixes?
- [ ] If adding `Fixes:`, did you verify this SHA actually *introduced* the bug?

```sh
# Find the commit that added the symbol or pattern you changed
git log --oneline -S '<changed-symbol>' -- <file>
# Confirm it builds broken without your fix, clean with it
```

  A wrong `Fixes:` tag causes incorrect stable backports — verify it, don't guess.

- [ ] `Cc: stable@vger.kernel.org` if the fix applies to stable kernels?
- [ ] To/Cc list reflects `get_maintainer.pl` output, not an address found elsewhere?
- [ ] `Signed-off-by` is present exactly once (added by `git commit -s`)?

### 6. Commit hygiene

- [ ] Does the commit do exactly one thing? Fix + unrelated cleanup = two commits.
- [ ] Have you read `git diff HEAD` line by line before staging?
  - No debug `pr_info()`/`pr_debug()` left in
  - No commented-out old code
  - No unrelated whitespace changes mixed in
  - Nothing that made sense during development but is wrong in the final patch

---

## Part B — Reviewer / maintainer workflow (patches from others)

### Step 1 — Fetch and apply

```sh
# Fetch from lore using b4
b4 am <message-id>
# e.g.:
b4 am 20260619082133.3504146-1-arnd@kernel.org

# Apply to a dedicated review branch in linux-dev
cd ~/git/linux-dev
git checkout -b review/<date>_<slug>.mbx
git am *.mbx
```

`b4 am` shows the thread summary (replies, Reviewed-by/Acked-by trailers already
present) before applying. If the thread already has a maintainer Ack, a Tested-by
may still add value — build/boot evidence is different from code review.

### Step 2 — Understand the patch

Before running any tool, read the patch and answer:

- [ ] Is this the latest version? Check the `b4 am` thread summary for v2/v3
  before investing review time in an outdated revision.
- [ ] Is a reproducer stated in the patch description?
- [ ] Is the root cause identified (not just "this fixes the warning")?
- [ ] Does the fix address the root cause, or only silence a symptom?
- [ ] Does the fix look correct for the stated root cause?

If you cannot answer the last four from the patch description alone, the patch is
under-documented — that is itself a review finding.

### Step 3 — Build verification

```sh
cd ~/git/kernel-test
make verify-patch \
    FILES=<path/to/file.o> \
    BASE=<kernel-version-before-patch> \
    ARCHS="arm64 x86_64" \
    COMPILER=both
```

Expected results per verdict:

| Verdict | Meaning |
|---|---|
| `FIXED` | Patch resolves the stated errors — consistent with the claim |
| `UNCHANGED-PASS` | No errors on this combo before or after — good |
| `UNCHANGED-FAIL` | Errors remain after patch — fix is incomplete or wrong combo |
| `REGRESSION` | Patch introduces new errors — do not apply |

- [ ] At least two architectures verified (arm64 + x86_64 minimum)?
- [ ] Both GCC and Clang tested?
- [ ] No `REGRESSION` verdicts?
- [ ] Does the affected code have `depends on ARCH_X || COMPILE_TEST`? If so,
  verify `CONFIG_COMPILE_TEST=y` was set — otherwise a non-native arch PASS
  means the code was never built.
- [ ] No new `: warning:` lines in the after-logs?

```sh
grep ': warning:' build/verify-patch/logs-*/arm64-gcc-after.log
```

Save the log directory path — you will quote it in the Tested-by reply.

### Step 4 — Runtime verification (if applicable)

Build-only patches (allmodconfig failures, compile errors): Step 3 is sufficient.

Patches touching runtime behaviour, driver logic, or locking:

```sh
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=<affected-arch>
```

- [ ] Kernel boots successfully?
- [ ] Affected functionality works (run the relevant custom test if one exists)?
- [ ] No new oops or warnings in dmesg?

### Step 5 — Apply cleanly to current tip?

```sh
cd ~/git/linux-dev
git fetch origin
git log --oneline -1 origin/master  # or the target subsystem branch
git checkout -b check/applies-to-tip
git cherry-pick <patch-sha>
```

- [ ] Applies without conflicts to the current tip of the target tree?
- [ ] If conflicts exist, are they trivial (context-only) or substantive?

### Step 6 — Respond on the thread

**Tested-by** — you verified it builds and/or boots correctly:

```
Tested-by: Benjamin Boortz <bennib@mailbox.org>

Verified with kernel-test verify-patch (<config>, <arch(s)>,
<compiler(s)>, BASE=<version>):

  before: N errors
  after:  PASS
  verdict: FIXED
```

**Reviewed-by** — you read the code and believe it is correct:

```
Reviewed-by: Benjamin Boortz <bennib@mailbox.org>
```

Only add Reviewed-by when you have read and understood the patch logic — it is a
stronger statement than Tested-by.

**Feedback** — if you found an issue:

State what you found concisely. Quote the specific lines. Suggest a fix if you
have one. Do not send Tested-by or Reviewed-by in the same reply as substantive
concerns.

Send using:

```sh
cd ~/git/linux-dev && git send-email \
    --in-reply-to="<original-message-id>" \
    --to="<patch-author>" \
    --to="<subsystem-list>" \
    --cc="linux-kernel@vger.kernel.org"
```

---

## Reference: verify-patch quick commands

```sh
# Minimal two-arch build check, before/after comparison
make verify-patch \
    FILES=security/landlock/fs.o \
    BASE=v7.2-rc5 \
    ARCHS="arm64 x86_64"

# Full four-arch sweep, Clang only
make verify-patch \
    FILES=drivers/net/ethernet/myricom/myri10ge/myri10ge.o \
    BASE=v7.2-rc5 \
    COMPILER=clang

# Directory target (all .o files in the subsystem)
make verify-patch \
    FILES=security/landlock/ \
    BASE=v7.2-rc5 \
    CLEAN=1
```

Logs land in `build/verify-patch/logs-<timestamp>/`. Attach or quote from
`<arch>-<compiler>-before.log` / `<arch>-<compiler>-after.log` in LKML replies.

---

## Reference: common checks and their tools

| Check | Command |
|---|---|
| Build (multi-arch/compiler) | `make verify-patch FILES=... BASE=...` |
| Boot test | `make all NO_FETCH=1 CONFIGS=defconfig ARCHS=...` |
| Warning delta | `grep ': warning:' build/verify-patch/logs-*/<combo>-after.log` |
| Style / format | `git format-patch -1 --stdout \| scripts/checkpatch.pl --strict -` |
| To/Cc recipients | `git format-patch -1 --stdout \| scripts/get_maintainer.pl` |
| Fetch patch from lore | `b4 am <message-id>` |
| Verify Fixes: SHA introduced bug | `git log --oneline -S '<changed-symbol>' -- <file>` |
| Check applied to subsystem tree | `git log <remote>/<branch> \| grep <topic>` |
| Diff before staging | `git diff HEAD` |
