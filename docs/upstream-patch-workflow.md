# Upstream kernel patch workflow

How to go from a kernel-test failure to a submitted upstream patch.

---

## Step 1: Identify the failure

Run the test suite and check `configs/archive_failed/index.txt` for new entries:

```sh
make all NO_FETCH=1
cat configs/archive_failed/index.txt
```

A `BUILD_FAIL` entry with a one-line compiler error is the clearest starting point.
`BOOT_FAIL` entries may need more investigation of `dmesg.txt` in the report dir.

---

## Step 2: Find the root cause

**For a BUILD_FAIL** — read the compiler error from the index detail line.
Identify which source file and line triggered it, then find the Kconfig entry
that should have selected the missing symbol:

```sh
grep -n 'is_generic\|GENERIC_PINCONF' drivers/pinctrl/pinctrl-bm1880.c
grep -A10 'PINCTRL_BM1880' drivers/pinctrl/Kconfig
```

**Find which commit introduced the bug** (`Fixes:` tag source):

```sh
cd ~/git/linux
git blame -L <line>,<line> <file>
# e.g.:
git blame -L 1288,1288 drivers/pinctrl/pinctrl-bm1880.c
```

The commit hash (first field) and subject become the `Fixes:` tag.

---

## Step 3: Create a design doc branch

```sh
cd ~/git/kernel-test
git checkout -b docs/<topic>
```

Create `docs/<topic>.md` capturing:
- Bug description and affected file/line
- How it was found (config, arch, version)
- Root cause
- Minimal reproducer
- Fix
- Upstream submission details (mailing list, maintainer)

Commit and push; open a PR when ready.

---

## Step 4: Write a minimal reproducer

Prefer `tinyconfig` — smallest base, fastest to confirm:

```sh
cd ~/git/linux
make ARCH=<arch> CROSS_COMPILE=<prefix> tinyconfig
scripts/config --enable CONFIG_<DEP>
scripts/config --enable CONFIG_<DRIVER>
make ARCH=<arch> CROSS_COMPILE=<prefix> olddefconfig
make ARCH=<arch> CROSS_COMPILE=<prefix> <driver-object>
```

`olddefconfig` respects `depends on`: if a driver has `depends on ARCH_X || COMPILE_TEST`
and neither is set, it silently drops the driver even if it was force-enabled.
Enable `CONFIG_COMPILE_TEST` whenever the driver has such an arch guard.

---

## Step 5: Apply and verify the fix

Apply the fix to `~/git/linux` (do not commit yet):

```sh
git apply ~/git/linux-dev/drivers/pinctrl/bug.diff
# or edit the file directly
```

Verify the reproducer now builds cleanly, then confirm with `make replay`:

```sh
cd ~/git/kernel-test
make replay CONFIG_FILE=configs/archive_failed/kconfig-<name>-BUILD_FAIL.config
```

Expected: `BUILD_FAIL → PASS`, boot OK, all tests pass.

---

## Step 6: Commit the patch

Work in a dedicated tree (e.g. `~/git/linux-dev`):

```sh
cd ~/git/linux-dev
git add <file>
git commit -s
```

**Commit message format:**

```
subsystem: component: short imperative description

Body explaining what is broken and why. Imperative mood throughout.
Do not start with "This patch". Lines ≤ 75 chars.

Compiler error (indented, treated as quoted — exempt from 75-char limit):

  path/to/file.c:NN: error: 'struct foo' has no member named 'bar'

Found by <how>. Add the missing <fix> to fix the build.

Fixes: <12-char-sha> ("<original commit subject>")
Cc: stable@vger.kernel.org
Signed-off-by: Your Name <your@email>

---
Reproducer (tinyconfig, <arch>, without patch):

  make ARCH=<arch> CROSS_COMPILE=<prefix> tinyconfig
  scripts/config --enable CONFIG_<DEP>
  scripts/config --enable CONFIG_<DRIVER>
  make ARCH=<arch> CROSS_COMPILE=<prefix> olddefconfig
  make ARCH=<arch> CROSS_COMPILE=<prefix> <driver>.o
```

**Key rules:**
- Lines starting with `#` are stripped by git — rephrase to avoid leading `#`
- Everything after `---` is excluded from `git log` (shown in email only)
- `Fixes:` uses exactly 12 hex chars of the SHA
- `Cc: stable@vger.kernel.org` requests stable backport for build/runtime fixes
- `Signed-off-by` is added automatically by `git commit -s` — do not add a second one

---

## Step 7: Validate

```sh
git format-patch -1 --stdout | scripts/checkpatch.pl --strict -
```

Must exit: `0 errors, 0 warnings`. Fix any warnings before sending.

```sh
git format-patch -1 --stdout | scripts/get_maintainer.pl
```

Note the exact email addresses — use what `get_maintainer.pl` returns, not
what you find elsewhere (maintainer addresses change over time).

---

## Step 8: Generate and send

```sh
git format-patch -1
```

```sh
git send-email \
  --to <primary-list@vger.kernel.org> \
  --cc <maintainer@kernel.org> \
  --cc <original-author@example.com> \
  --cc linux-kernel@vger.kernel.org \
  0001-<slug>.patch
```

`git send-email` will prompt to confirm recipients and show a preview before
sending. Review it carefully — you cannot unsend.

---

## Step 9: Track the patch

- **Your inbox** — maintainer replies with `"Applied, thanks"` or a review comment
- **lore.kernel.org** — full mailing list archive, search by subject or sender
- **linux-next** — once picked up, the commit appears within days:

```sh
cd ~/git/kernel-test-next
make fetch-next
git log --oneline origin/master | grep -i <keyword>
```

If no reply after 2–3 weeks, send a polite ping on the same thread.

---

## Step 10: Update the design doc

After sending, update `docs/<topic>.md`:
- Record the patch message-id from lore.kernel.org
- Note when it appeared in linux-next
- Note which kernel release it shipped in

---

## Reference: common mailing lists

| Subsystem | List | Maintainer |
|---|---|---|
| pinctrl / gpio | `linux-gpio@vger.kernel.org` | `linusw@kernel.org` |
| networking | `netdev@vger.kernel.org` | |
| all patches | `linux-kernel@vger.kernel.org` | |
| stable backports | `stable@vger.kernel.org` | |
