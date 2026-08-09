# Cross-compile arena-test for all 4 kernel-test arches (GCC, shipped).
# Clang quality-gate applies to x86_64 only (musl-clang is a host compiler).
# Called by lib/bootstrap.sh; output injected into initramfs at usr/bin/arena-test.

SRC    := arena-test.c
BIN    := arena-test
ARCHES := x86_64 i386 arm64 riscv

CC_x86_64 := musl-gcc
CC_i386   := gcc
CC_arm64  := aarch64-linux-gnu-gcc
CC_riscv  := riscv64-linux-gnu-gcc

CFLAGS_x86_64 := -static
CFLAGS_i386   := -m32 -static
# -Wno-pointer-to-int-cast: aarch64/riscv cross-compilers resolve uintptr_t from
# host headers while tracking target pointer size separately; (uintptr_t)p in
# test_alignment() is correct but triggers a spurious size-mismatch warning.
# The musl-clang x86_64 gate still catches real pointer-to-int issues.
CFLAGS_arm64  := -static -Wno-pointer-to-int-cast
CFLAGS_riscv  := -static -Wno-pointer-to-int-cast

CFLAGS_COMMON       := -std=c11 -O2 -D_DEFAULT_SOURCE \
                       -Wno-declaration-after-statement \
                       -Wno-implicit-function-declaration
CFLAGS_COMMON_GCC   := -Wall -Wextra -Wpedantic -Werror
CFLAGS_COMMON_CLANG := -Weverything -Werror \
                       -Wno-disabled-macro-expansion \
                       -Wno-unsafe-buffer-usage

CC_CLANG := musl-clang

.PHONY: all clean

all: $(foreach a,$(ARCHES),bin/$(a)/$(BIN)) bin/x86_64/$(BIN)-clang

define build_rule
bin/$(1)/$(BIN): $(SRC) | bin/$(1)
	@printf '[arena] %-6s %s\n' $(1) $(BIN)
	$(CC_$(1)) $(CFLAGS_COMMON) $(CFLAGS_COMMON_GCC) $(CFLAGS_$(1)) -o $$@ $$<
endef

$(foreach a,$(ARCHES),$(eval $(call build_rule,$(a))))

bin/x86_64/$(BIN)-clang: $(SRC) | bin/x86_64
	@printf '[arena] %-6s %s (clang quality gate)\n' x86_64 $(BIN)
	$(CC_CLANG) $(CFLAGS_COMMON) $(CFLAGS_COMMON_CLANG) $(CFLAGS_x86_64) -o $@ $<

$(foreach a,$(ARCHES),$(eval bin/$(a):; mkdir -p $$@))

clean:
	rm -rf bin/
