# linux-next Workflow

linux-next is the integration tree where subsystem patches land before Linus pulls
them into mainline.  Testing against it exposes missing Kconfig `select` lines,
header inclusion bugs, and other integration issues before they reach an `-rc` tag.

---

## Setup (one-time)

```sh
# 1. Clone linux-next
git clone git://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git \
    ~/git/linux-next

# 2. Clone the test harness as kernel-test-next
git clone https://github.com/bb-claw/kernel-test.git ~/git/kernel-test-next

# 3. Bootstrap dependencies (if not already done)
cd ~/git/kernel-test-next
make bootstrap
```

The preset `presets/kernel-test-next.mk` is auto-loaded because the clone directory
is named `kernel-test-next`.  It sets:

```makefile
KERNEL_TREE  = ~/git/linux-next
LABEL        = next
LINUX_NEXT   = 1
```

---

## Daily fetch

linux-next has no rc tags — it is a daily-rebased `master` branch:

```sh
cd ~/git/kernel-test-next
make fetch-next          # git fetch origin master + reset --hard + write build/.kernel-version
make info                # confirm the version
```

---

## Run the full suite

```sh
make all NO_FETCH=1
```

Or target a specific config to check a suspected area:

```sh
make all NO_FETCH=1 CONFIGS=rand500config ARCHS=arm64
```

---

## Replay an archived failing config

An archived `BUILD_FAIL` config from another clone can be retested against linux-next:

```sh
make replay \
  CONFIG_FILE=configs/archive_failed/kconfig-rand500config-arm64-<sha>.config \
  CONFIGS=rand500config ARCHS=arm64
```

`KERNEL_TREE` is already set to `~/git/linux-next` by the preset — no extra flags needed.

---

## Apply a local patch and verify

```sh
# 1. Apply the patch to linux-next
cd ~/git/linux-next
git apply /path/to/fix.patch
# or: git am fix.patch

# 2. Rebuild and retest (no fetch needed — tree already up to date)
cd ~/git/kernel-test-next
make all NO_FETCH=1 CONFIGS=rand500config ARCHS=arm64

# 3. Compare with the pre-patch result
make diff
```

To check whether linux-next already contains the fix before applying:

```sh
git -C ~/git/linux-next log --oneline -- <file> | head -10
git -C ~/git/linux-next grep "select REGMAP_MMIO" drivers/pinctrl/Kconfig
```

---

## Prepare and submit a patch

### 1. Identify the introducing commit

```sh
cd ~/git/linux-next
git log --oneline -- path/to/file | head -20
# or: git log -S 'symbol_name' --oneline -- path/to/file
```

**Note:** linux-next and mainline clones are shallow — `git log -S` and `git blame`
may hit the boundary (commits prefixed with `^`).  Fall back to the cgit web interface:

```
https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/log/path/to/file
```

The `Fixes:` tag must point to the commit that *introduced* the bug, not necessarily
the file shown in the error message.

### 2. Apply the fix to your development tree

Work in a dedicated dev tree (e.g. `~/git/linux-dev`) checked out at the current rc
tag — not in linux-next directly.  Patches go to the subsystem maintainer who pulls
them into linux-next:

```sh
cd ~/git/linux-dev
git checkout v7.2-rc3    # or latest rc tag
# edit the file
git add path/to/file
git commit -s
```

Commit message format (example: missing Kconfig `select`):

```
subsystem: driver: add missing select DEPENDENCY

The driver calls foo() via <linux/mfd/bar.h>, which internally uses
baz() and requires DEPENDENCY.  The Kconfig entry does not select it,
causing a build failure when no other driver in the config pulls in
DEPENDENCY:

  include/linux/mfd/bar.h:19:51: error: ...
  drivers/.../driver.c:910:16: error: ...

Found by randconfig testing on arm64; tinyconfig reproducer below.

Fixes: <sha> ("<exact commit title>")
Cc: stable@vger.kernel.org
Signed-off-by: Your Name <your@email>
---
Reproducer (tinyconfig, arm64, without patch):

  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- tinyconfig
  scripts/config --enable CONFIG_SUBSYSTEM
  scripts/config --enable CONFIG_DRIVER
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
      drivers/path/driver.o
  -> CONFIG_DEPENDENCY absent, build fails as shown above
```

Content after `---` is visible in the email but stripped by `git am` — the right place
for reproducers.  Use the function the driver *directly* calls in the description, not
a transitive dependency that appears in the error message.

### 3. Run checkpatch

```sh
git format-patch -1 HEAD
~/git/linux/scripts/checkpatch.pl --strict 0001-*.patch
```

Fix all errors and warnings before sending.  `--strict` catches trailing whitespace
and other style issues that the default mode skips.

### 4. Find the right recipients

```sh
~/git/linux/scripts/get_maintainer.pl 0001-*.patch
```

Routing rules from the output:
- `(maintainer:...)` and `(blamed_fixes:...)` → `--to`
- `(open list:...)` / mailing lists → `--cc`
- `stable@vger.kernel.org` → `--cc` (even if already in the commit body)

```sh
git send-email \
  --to="maintainer@example.com" \
  --to="blamed.author@example.com" \
  --cc="linux-subsystem@vger.kernel.org" \
  --cc="linux-kernel@vger.kernel.org" \
  --cc="stable@vger.kernel.org" \
  0001-*.patch
```

`git send-email` shows a preview with full headers before sending — verify the From
address and recipient list, then type `y`.

### 5. Monitor the mailing list

Search lore.kernel.org for replies:

```
https://lore.kernel.org/linux-gpio/?q=subject+keyword
```

Maintainers typically reply within a few days.  If accepted, the patch appears in
linux-next within a week via the subsystem tree.

If asked for a v2: resend with `[PATCH v2]` in the subject and a `Changes in v2:`
section after `---`.

---

## Verify the fix landed in linux-next

```sh
cd ~/git/kernel-test-next
make fetch-next
git -C ~/git/linux-next log --oneline -- drivers/pinctrl/Kconfig | head -5
make all NO_FETCH=1 CONFIGS=rand500config ARCHS=arm64
```

A PASS result confirms the fix is live in the integration tree.
