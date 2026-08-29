# tests/common.mk — shared C program build rules
#
# Required (set before including):
#   SRC  := my-program.c
#   BIN  := my-program
#
# Optional overrides (set before including):
#   CC_x86_64           ?= musl-gcc       (override: := gcc for nolibc)
#   CC_CLANG            ?= musl-clang
#   CFLAGS_GCC_EXTRA    :=                (extra GCC flags, all arches)
#   CFLAGS_CLANG_EXTRA  :=                (extra Clang suppressions)
#   CFLAGS_x86_64_EXTRA :=                (arch-specific extras)
#   CFLAGS_arm64_EXTRA  :=                (e.g. -Wno-pointer-to-int-cast)
#   CFLAGS_riscv_EXTRA  :=                (e.g. -Wno-pointer-to-int-cast)
#   CFLAGS_i386_EXTRA   :=
#   LOG_TAG             := $(BIN)         (build log prefix)
#   OPTIMIZATION        := speed|size|debug  (default: speed = -O2)
#
# Modes (set before including):
#   (default)    cross-compiled: 4 arches + Clang x86_64 quality gate
#   HOST_ONLY=1  x86_64 only; GCC = quality gate, Clang = shipped binary
#   FLAGS_ONLY=1 variables only — no build rules (for multi-binary Makefiles)
#   EMULATOR=1   host clang build with ASAN/UBSAN; provides CC RM MD
#                CFLAGS_OBJ CFLAGS_EXE (combine with FLAGS_ONLY=1)
#                Knobs: OPTIMIZATION=DEBUG|SIZE|NO  STATIC=1  NOSTD=1
#
# Targets: all  clean  valgrind  scan

# Absolute path to this file's directory (tests/); used to locate .clang-format.
_TESTS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Prevent fmt/scan from becoming the default goal when FLAGS_ONLY=1 skips
# the all: target inside the guard (first target wins in make).
.DEFAULT_GOAL := all

ARCHES ?= x86_64 i386 arm64 riscv

CC_x86_64   ?= musl-gcc
CC_i386     ?= gcc
CC_arm64    ?= aarch64-linux-gnu-gcc
CC_riscv    ?= riscv64-linux-gnu-gcc
CC_CLANG    ?= musl-clang
CC_VALGRIND ?= gcc

CFLAGS_x86_64 ?= -static
CFLAGS_i386   ?= -m32 -static
CFLAGS_arm64  ?= -static
CFLAGS_riscv  ?= -static

CFLAGS_x86_64_EXTRA ?=
CFLAGS_i386_EXTRA   ?=
CFLAGS_arm64_EXTRA  ?=
CFLAGS_riscv_EXTRA  ?=
CFLAGS_GCC_EXTRA    ?=
CFLAGS_CLANG_EXTRA  ?=

ifeq ($(OPTIMIZATION),size)
_OPT_COMMON := -Os
else ifeq ($(OPTIMIZATION),debug)
_OPT_COMMON := -O0 -g
else
_OPT_COMMON := -O2
endif

CFLAGS_COMMON ?= -std=c17 $(_OPT_COMMON) -D_DEFAULT_SOURCE \
    -Wno-declaration-after-statement \
    -Wno-implicit-function-declaration

CFLAGS_GCC ?= -Wall -Wextra -Wpedantic -Werror \
    -Wformat=2 -Wno-unused-parameter -Wshadow \
    -Wwrite-strings -Wstrict-prototypes -Wold-style-definition \
    -Wredundant-decls -Wnested-externs -Wmissing-include-dirs \
    -Wjump-misses-init -Wlogical-op

CFLAGS_CLANG ?= -Weverything -Werror \
    -Wno-unknown-warning-option \
    -Wno-disabled-macro-expansion \
    -Wno-unsafe-buffer-usage

CFLAGS_VALGRIND_FLAGS ?= -std=c17 -g -O1 -D_DEFAULT_SOURCE -static \
    -Wno-declaration-after-statement \
    -Wno-implicit-function-declaration \
    -fanalyzer -Wall -Wextra -Wpedantic -Werror

LOG_TAG ?= $(BIN)

ifeq ($(EMULATOR),1)

# ── Emulator mode ──────────────────────────────────────────────────────────────
# Host-only clang build with ASAN/UBSAN.  Always active regardless of
# FLAGS_ONLY.  Provides: CC  RM  MD  CFLAGS_OBJ  CFLAGS_EXE

ifeq ($(origin CC),default)
CC := clang
endif

RM ?= rm -f
MD ?= mkdir -p

OPTIMIZATION ?= DEBUG
STATIC       ?= 0
NOSTD        ?= 0

# Normalize to uppercase so SIZE/size/Size all work the same way.
override OPTIMIZATION := $(shell echo '$(OPTIMIZATION)' | tr '[:lower:]' '[:upper:]')

_RDYNAMIC :=
_ASAN     := -fsanitize=address,undefined
_LOPT     :=

ifeq ($(strip $(OPTIMIZATION)),SIZE)
# Release build: optimize for size, strip debug info, no sanitizers.
_OPT      := -Os -g0 -ffunction-sections -fdata-sections \
             -fno-asynchronous-unwind-tables
_LOPT     := -Wl,--gc-sections
_ASAN     :=
else ifeq ($(strip $(OPTIMIZATION)),ULTRA)
# Smallest possible binary: Oz > Os for size, LTO eliminates dead code across
# TU boundaries, unwind tables removed, gc-sections drops unused sections.
_OPT      := -Oz -g0 -flto -ffunction-sections -fdata-sections \
             -fno-asynchronous-unwind-tables -fno-unwind-tables
_LOPT     := -Wl,--gc-sections
_ASAN     :=
else ifeq ($(strip $(OPTIMIZATION)),DEBUG)
_OPT      := -Og -g
_RDYNAMIC := -rdynamic
else ifeq ($(strip $(OPTIMIZATION)),NO)
_OPT      := -O0
else
_OPT      := -O2
endif

ifeq ($(strip $(STATIC)),1)
_LINK := -static
else
_LINK :=
endif

ifeq ($(strip $(NOSTD)),1)
_NOSTD := -nostdlib -ffreestanding
else
_NOSTD :=
endif

_CFLAGS_WARN := -Wall -Wextra -Wpedantic -Werror \
    -Wformat=2 -Wno-unused-parameter -Wshadow \
    -Wwrite-strings -Wstrict-prototypes -Wold-style-definition \
    -Wredundant-decls -Wnested-externs -Wmissing-include-dirs

_CFLAGS_BASE := -std=c17 -D_DEFAULT_SOURCE $(_OPT) $(_ASAN) $(_NOSTD)

CFLAGS_OBJ := $(_CFLAGS_WARN) $(_CFLAGS_BASE) -Wno-unused-command-line-argument -c
CFLAGS_EXE := $(_CFLAGS_WARN) $(_CFLAGS_BASE) $(_LINK) $(_RDYNAMIC) $(_LOPT)

else  # EMULATOR != 1

# ── Non-emulator fallback ──────────────────────────────────────────────────────
# Plain optimized build without sanitizers; used when EMULATOR=0 is passed.
# Provides the same CC/RM/MD/CFLAGS_OBJ/CFLAGS_EXE interface so downstream
# Makefiles always have valid compiler settings.

ifeq ($(origin CC),default)
CC := clang
endif

RM ?= rm -f
MD ?= mkdir -p

_CFLAGS_WARN := -Wall -Wextra -Wpedantic -Werror \
    -Wformat=2 -Wno-unused-parameter -Wshadow \
    -Wwrite-strings -Wstrict-prototypes -Wold-style-definition \
    -Wredundant-decls -Wnested-externs -Wmissing-include-dirs

CFLAGS_OBJ := $(_CFLAGS_WARN) -std=c17 -D_DEFAULT_SOURCE -O2 -c
CFLAGS_EXE := $(_CFLAGS_WARN) -std=c17 -D_DEFAULT_SOURCE -O2

endif  # EMULATOR

ifneq ($(FLAGS_ONLY),1)

ifeq ($(HOST_ONLY),1)

# ── Host-only mode ────────────────────────────────────────────────────────────
# GCC = quality gate (not shipped); Clang = shipped binary. x86_64 only.

.PHONY: all clean valgrind

all: bin/$(BIN)-gcc bin/$(BIN)

bin/$(BIN)-gcc: $(SRC) | bin
	@printf '[$(LOG_TAG)] gcc   %s\n' $@
	musl-gcc $(CFLAGS_COMMON) $(CFLAGS_GCC) $(CFLAGS_GCC_EXTRA) -static -o $@ $<

bin/$(BIN): $(SRC) | bin
	@printf '[$(LOG_TAG)] clang %s\n' $@
	$(CC_CLANG) $(CFLAGS_COMMON) $(CFLAGS_CLANG) $(CFLAGS_CLANG_EXTRA) -static -o $@ $<

bin:
	mkdir -p bin

valgrind: bin/$(BIN)-valgrind

bin/$(BIN)-valgrind: $(SRC) | bin
	@printf '[$(LOG_TAG)] gcc   %s (valgrind/glibc)\n' $@
	$(CC_VALGRIND) $(CFLAGS_VALGRIND_FLAGS) $(CFLAGS_GCC_EXTRA) -o $@ $<

clean:
	rm -rf bin/

else

# ── Cross-compiled mode ───────────────────────────────────────────────────────
# GCC shipped for all 4 arches; Clang x86_64 quality gate (not shipped).

.PHONY: all clean valgrind

all: $(foreach a,$(ARCHES),bin/$(a)/$(BIN)) bin/x86_64/$(BIN)-clang

define build_rule
bin/$(1)/$(BIN): $(SRC) | bin/$(1)
	@printf '[$(LOG_TAG)] %-6s %s\n' $(1) $(BIN)
	$(CC_$(1)) $(CFLAGS_COMMON) $(CFLAGS_GCC) $(CFLAGS_GCC_EXTRA) $(CFLAGS_$(1)) $(CFLAGS_$(1)_EXTRA) -o $$@ $$<
endef

$(foreach a,$(ARCHES),$(eval $(call build_rule,$(a))))

bin/x86_64/$(BIN)-clang: $(SRC) | bin/x86_64
	@printf '[$(LOG_TAG)] %-6s %s (clang quality gate)\n' x86_64 $(BIN)
	$(CC_CLANG) $(CFLAGS_COMMON) $(CFLAGS_CLANG) $(CFLAGS_CLANG_EXTRA) $(CFLAGS_x86_64) -o $@ $<

$(foreach a,$(ARCHES),$(eval bin/$(a):; mkdir -p $$@))

valgrind: bin/x86_64/$(BIN)-valgrind

bin/x86_64/$(BIN)-valgrind: $(SRC) | bin/x86_64
	@printf '[$(LOG_TAG)] %-6s %s (valgrind/glibc)\n' x86_64 $(BIN)
	$(CC_VALGRIND) $(CFLAGS_VALGRIND_FLAGS) $(CFLAGS_GCC_EXTRA) -o $@ $<

clean:
	rm -rf bin/

endif  # HOST_ONLY

.PHONY: scan
scan:
	@printf '[$(LOG_TAG)] clang %s (analyzer)\n' $(SRC)
	clang --analyze -Xanalyzer -analyzer-output=text \
	    $(CFLAGS_COMMON) -Werror -o /dev/null $(SRC)

endif  # FLAGS_ONLY

.PHONY: fmt
fmt:
	clang-format --style=file:$(_TESTS_DIR).clang-format -i $(SRC) $(SRCS)
