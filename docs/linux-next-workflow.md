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
git log --oneline -- drivers/pinctrl/Kconfig | head -20
# or: git log -S 'PINCTRL_MICROCHIP_SGPIO' --oneline
```

### 2. Apply the fix to your mainline tree

Work against `~/git/linux` (Linus's tree), not linux-next directly — patches are
submitted to the subsystem maintainer who then pulls them into linux-next:

```sh
cd ~/git/linux
git checkout -b fix/pinctrl-microchip-sgpio-regmap-mmio
# edit drivers/pinctrl/Kconfig
git add drivers/pinctrl/Kconfig
git commit -s
```

Commit message format:

```
pinctrl: microchip-sgpio: add missing select REGMAP_MMIO

PINCTRL_MICROCHIP_SGPIO calls devm_regmap_init_mmio() via ocelot.h but
does not select REGMAP_MMIO.  Without the select, olddefconfig leaves
CONFIG_REGMAP_MMIO unset and the build fails:

  include/linux/mfd/ocelot.h:19:51: error: 'struct regmap_config'
    declared inside parameter list
  include/linux/mfd/ocelot.h:34:24: error: implicit declaration of
    function 'devm_regmap_init_mmio'
  drivers/pinctrl/pinctrl-microchip-sgpio.c:910:16: error: variable
    'regmap_config' has initializer but incomplete type
  drivers/pinctrl/pinctrl-microchip-sgpio.c:911:18: error: 'struct
    regmap_config' has no member named 'reg_bits'

Fixes: 68c873363a78 ("pinctrl: ocelot: add SGPIO driver")
Cc: stable@vger.kernel.org
Signed-off-by: Your Name <your@email>
```

### 3. Run checkpatch

```sh
cd ~/git/linux
git format-patch -1 HEAD -o /tmp/
scripts/checkpatch.pl /tmp/0001-pinctrl-microchip-sgpio-add-missing-select-REGMAP_MMIO.patch
```

Fix any warnings before sending.

### 4. Find the right recipients

```sh
scripts/get_maintainer.pl /tmp/0001-*.patch
```

Typical output for `drivers/pinctrl/Kconfig`:
```
Linus Walleij <linusw@kernel.org>             (maintainer: PINCTRL SUBSYSTEM)
linux-gpio@vger.kernel.org                    (open list)
linux-kernel@vger.kernel.org                  (open list)
```

Also add any co-authors of the introducing commit (from `git show <fixes-sha>`)
and `stable@vger.kernel.org` for the `Cc: stable` backport request.

### 5. Send via git send-email

```sh
git send-email \
  --to=linusw@kernel.org \
  --to=Steen.Hegelund@microchip.com \
  --cc=linux-gpio@vger.kernel.org \
  --cc=linux-arm-kernel@lists.infradead.org \
  --cc=linux-kernel@vger.kernel.org \
  --cc=stable@vger.kernel.org \
  /tmp/0001-*.patch
```

Configure `~/.gitconfig` once:

```ini
[sendemail]
    smtpserver = smtp.gmail.com
    smtpserverport = 587
    smtpencryption = tls
    smtpuser = your@gmail.com
```

### 6. Monitor the mailing list

Search lore.kernel.org for replies:

```
https://lore.kernel.org/linux-gpio/?q=PINCTRL_MICROCHIP_SGPIO
```

Maintainers typically reply within a few days.  If the patch is accepted, it
appears in linux-next within a week via the pinctrl-for-next tree.

---

## Verify the fix landed in linux-next

```sh
cd ~/git/kernel-test-next
make fetch-next
git -C ~/git/linux-next log --oneline -- drivers/pinctrl/Kconfig | head -5
make all NO_FETCH=1 CONFIGS=rand500config ARCHS=arm64
```

A PASS result confirms the fix is live in the integration tree.
