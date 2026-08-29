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
#
# Modes (set before including):
#   (default)    cross-compiled: 4 arches + Clang x86_64 quality gate
#   HOST_ONLY=1  x86_64 only; GCC = quality gate, Clang = shipped binary
#   FLAGS_ONLY=1 variables only — no build rules (for multi-binary Makefiles)
#
# Targets: all  clean  valgrind  scan

# Absolute path to this file's directory (tests/); used to locate .clang-format.
_TESTS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

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

CFLAGS_COMMON ?= -std=c17 -O2 -D_DEFAULT_SOURCE \
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

.PHONY: fmt
fmt:
	clang-format --style=file:$(_TESTS_DIR).clang-format -i $(SRC)

endif  # FLAGS_ONLY
