---
name: patch-workflow
description: Quality gate and review workflow for kernel patches — pre-send checklist for own patches + maintainer-style reviewer workflow for others
metadata:
  type: project
---

# Patch quality and review workflow

Full doc: `docs/patch-quality-workflow.md`
Authoring mechanics: `docs/upstream-patch-workflow.md`

---

## Pre-send quality gate (own patches)

Work through every item. A "no" is a blocker.

**Problem statement**
- Can you state the bug in one sentence without quoting the error?
- Is there a minimal reproducer (commands from scratch)?
- Is the reproducer in the commit message (after `---`)?

**Root cause**
- Is the root cause identified, not just the symptom?
- Does the fix address root cause — not silence a warning or paper over a symptom?
- Are other call sites / structs affected by the same underlying bug?
- Would a new call site in the same pattern automatically be safe? (If not, fix is in the wrong place.)

**Build verification**
```sh
make verify-patch FILES=<file.o> BASE=<current-rc> ARCHS="arm64 x86_64"
```
- arm64 + x86_64 minimum; both GCC and Clang; allmodconfig
- Verdict: FIXED or UNCHANGED-PASS
- Does affected code have `depends on ARCH_X || COMPILE_TEST`? If so, set `CONFIG_COMPILE_TEST=y` — otherwise a non-native arch PASS means the code was never built
- No new `: warning:` in after-logs: `grep ': warning:' build/verify-patch/logs-*/*-after.log`

**Runtime verification**
- Has the patched kernel booted (not just compiled)?
- `make all NO_FETCH=1 CONFIGS=defconfig ARCHS=<affected-arch>` passes?

**Format**
```sh
git format-patch -1 --stdout | scripts/checkpatch.pl --strict -
git format-patch -1 --stdout | scripts/get_maintainer.pl
```
- checkpatch: 0 errors, 0 warnings
- `Fixes:` tag for regression fixes — verify the SHA actually introduced the bug: `git log --oneline -S '<changed-symbol>' -- <file>`; a wrong `Fixes:` causes incorrect stable backports
- `Cc: stable@vger.kernel.org` for backportable fixes
- To/Cc from `get_maintainer.pl` output, not addresses found elsewhere

**Commit hygiene**
- Read `git diff HEAD` line by line: no debug prints, no commented-out code, no unrelated whitespace
- One thing per commit — fix + cleanup = two commits

---

## Reviewer / maintainer workflow (patches from others)

### 1 — Fetch and apply
```sh
b4 am <message-id>
cd ~/git/linux-dev
git checkout -b review/<date>_<slug>.mbx
git am *.mbx
```

### 2 — Read the patch first (before running tools)
- Is this the latest version? Check `b4 am` thread summary for v2/v3 before investing review time
- Is a reproducer stated in the patch description?
- Is the root cause identified (not just "this fixes the warning")?
- Does the fix address root cause, or only silence a symptom?
- Does the fix logic look correct for the stated root cause?

### 3 — Build verification
```sh
make verify-patch FILES=<file.o> BASE=<version-before-patch> \
    ARCHS="arm64 x86_64" COMPILER=both
```
- No REGRESSION verdicts
- `CONFIG_COMPILE_TEST=y` needed? (`depends on ARCH_X || COMPILE_TEST`)
- No new warnings: `grep ': warning:' build/verify-patch/logs-*/*-after.log`

### 4 — Runtime verification (driver/locking changes)
```sh
make all NO_FETCH=1 CONFIGS=defconfig ARCHS=<affected-arch>
```

### 5 — Applies to current tip?
```sh
git cherry-pick <sha>   # on a branch off current subsystem tip
```

### 6 — Respond
**Tested-by** (build/boot verified):
```
Tested-by: Benjamin Boortz <bennib@mailbox.org>

Verified with kernel-test verify-patch (<config>, <arch(s)>, <compiler(s)>, BASE=<version>):
  before: N errors  /  after: PASS  /  verdict: FIXED
```

**Reviewed-by** (code read and believed correct — stronger commitment than Tested-by)

Send: `git send-email --in-reply-to="<msgid>" --to=<author> --to=<list>`

---

## Why: root cause vs symptom

**Why:** Silencing a warning at a call site (e.g. `= {}` zero-init) hides the
analysis failure. A struct-level fix (e.g. explicit padding) means every future
call site is automatically safe. Arnd's landlock fix (2026-06-19) is the
reference example: `__pad` field in `struct layer_mask` vs `= {}` at three call sites.

**How to apply:** When writing or reviewing a fix, ask: "Would a new call site
in the same pattern be broken again?" If yes, the fix belongs at a higher level.
