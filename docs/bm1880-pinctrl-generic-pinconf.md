# pinctrl-bm1880: missing `select GENERIC_PINCONF`

Branch: `docs/bm1880-pinctrl-generic-pinconf`
Found: 2026-07-20 — v7.2-rc4 rand500config arm64 BUILD_FAIL

---

## Bug

`drivers/pinctrl/pinctrl-bm1880.c` initialises its `pinconf_ops` with
`.is_generic = true`, but `is_generic` is guarded by `#ifdef CONFIG_GENERIC_PINCONF`
in `include/linux/pinctrl/pinconf.h`.  The driver's Kconfig entry does not
`select GENERIC_PINCONF`, so any config that enables `CONFIG_PINCTRL_BM1880=y`
without also enabling `CONFIG_GENERIC_PINCONF=y` fails to compile.

Affected file: `drivers/pinctrl/pinctrl-bm1880.c:1288`
Affected kernel: v7.2-rc4 (commit `1590cf0329716306e948a8fc29f1d3ee87d3989f`)

---

## How it was found

`make all` on v7.2-rc4 with `rand500config arm64` randomly sampled
`CONFIG_PINCTRL_BM1880=y` without `CONFIG_GENERIC_PINCONF=y`.  The harness
reported `BUILD_FAIL` for that single config/arch combination; all other
14 configs passed.

---

## Reproducer

Confirmed on v7.2-rc4, arm64 cross-compile:

```sh
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- tinyconfig
scripts/config --enable CONFIG_PINCTRL
scripts/config --enable CONFIG_PINCTRL_BM1880
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    drivers/pinctrl/pinctrl-bm1880.o
```

`COMPILE_TEST` is not required — `scripts/config --enable` forces the value
regardless of the `depends on OF && (ARCH_BITMAIN || COMPILE_TEST)` guard,
and `olddefconfig` preserves it.

Expected output (build fails):

```
drivers/pinctrl/pinctrl-bm1880.c:1288:10: error: 'const struct pinconf_ops' \
  has no member named 'is_generic'
 1288 |         .is_generic = true,
      |          ^~~~~~~~~~
drivers/pinctrl/pinctrl-bm1880.c:1288:23: error: initialization of \
  'int (*)(struct pinctrl_dev *, unsigned int,  long unsigned int *)' \
  from 'int' makes pointer from integer without a cast [-Wint-conversion]
```

`CONFIG_GENERIC_PINCONF` is absent from `.config` after `olddefconfig`
because `PINCTRL_BM1880` never selects it.

---

## Root cause

`include/linux/pinctrl/pinconf.h`:

```c
struct pinconf_ops {
#ifdef CONFIG_GENERIC_PINCONF
	bool is_generic;
#endif
	int (*pin_config_get) (...);
	...
};
```

`drivers/pinctrl/Kconfig` for `PINCTRL_BM1880`:

```kconfig
config PINCTRL_BM1880
	bool "Bitmain BM1880 Pinctrl driver"
	depends on OF && (ARCH_BITMAIN || COMPILE_TEST)
	default ARCH_BITMAIN
	select PINMUX
	# missing: select GENERIC_PINCONF
```

Without the `select`, `CONFIG_GENERIC_PINCONF` is absent and the compiler
sees `.is_generic` as an unknown field — it falls through to the next field
(`pin_config_get`, a function pointer), causing both the member-not-found
and int-to-pointer errors.

---

## Fix

One-line change to `drivers/pinctrl/Kconfig`:

```diff
 config PINCTRL_BM1880
 	bool "Bitmain BM1880 Pinctrl driver"
 	depends on OF && (ARCH_BITMAIN || COMPILE_TEST)
 	default ARCH_BITMAIN
 	select PINMUX
+	select GENERIC_PINCONF
 	help
 	  Pinctrl driver for Bitmain BM1880 SoC.
```

---

## Upstream submission

File: `drivers/pinctrl/Kconfig`
Mailing list: `linux-gpio@vger.kernel.org`
Cc: `linux-kernel@vger.kernel.org`, `linus.walleij@linaro.org`

Suggested subject:
```
pinctrl: bm1880: select GENERIC_PINCONF to fix build without it
```

---

## Potential kernel-test changes

- No immediate change needed: the BUILD_FAIL is correctly detected and
  archived as `BUILD_FAIL` in `configs/archive_failed/`.
- Future: a post-build Kconfig consistency check could flag drivers that
  use `is_generic = true` in their `pinconf_ops` without `select GENERIC_PINCONF`
  — but this is a kernel-side issue and unlikely to recur once fixed upstream.
