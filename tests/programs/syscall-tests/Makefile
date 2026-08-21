# Cross-compile syscall-tests for all 4 kernel-test arches (GCC, shipped).
# Clang quality-gate applies to x86_64 only (musl-clang is a host compiler).
# Called by lib/bootstrap.sh; output injected into initramfs at usr/bin/syscall-tests.

SRC    := syscall-tests.c
BIN    := syscall-tests
ARCHES := x86_64 i386 arm64 riscv

CC_x86_64 := musl-gcc
CC_i386   := gcc
CC_arm64  := aarch64-linux-gnu-gcc
CC_riscv  := riscv64-linux-gnu-gcc

CFLAGS_x86_64 := -static
CFLAGS_i386   := -m32 -static
# -Wno-pointer-to-int-cast: aarch64/riscv cross-compilers fire spuriously on
# (int)syscall() casts where target pointer size differs from host int.
CFLAGS_arm64  := -static -Wno-pointer-to-int-cast
CFLAGS_riscv  := -static -Wno-pointer-to-int-cast

CFLAGS_COMMON       := -std=c11 -O2 -D_DEFAULT_SOURCE \
                       -Wno-declaration-after-statement \
                       -Wno-implicit-function-declaration
CFLAGS_COMMON_GCC   := -Wall -Wextra -Wpedantic -Werror
CFLAGS_COMMON_CLANG := -Weverything -Werror \
                       -Wno-unknown-warning-option \
                       -Wno-disabled-macro-expansion \
                       -Wno-unsafe-buffer-usage \
                       -Wno-cast-align \
                       -Wno-shorten-64-to-32 \
                       -Wno-sign-conversion
# -Wno-cast-align: ring buffer pointer arithmetic (uint32_t * from char *)
# -Wno-shorten-64-to-32: deliberate (int)syscall() on 64-bit hosts
# -Wno-sign-conversion: mixed signed/unsigned in ring buffer index math

CC_CLANG := musl-clang

CC_VALGRIND    := gcc
CFLAGS_VALGRIND := -std=c11 -g -O1 -D_DEFAULT_SOURCE -static \
                   -Wno-declaration-after-statement \
                   -Wno-implicit-function-declaration \
                   -fanalyzer -Wall -Wextra -Wpedantic -Werror

.PHONY: all clean valgrind scan

all: $(foreach a,$(ARCHES),bin/$(a)/$(BIN)) bin/x86_64/$(BIN)-clang

define build_rule
bin/$(1)/$(BIN): $(SRC) | bin/$(1)
	@printf '[syscall] %-6s %s\n' $(1) $(BIN)
	$(CC_$(1)) $(CFLAGS_COMMON) $(CFLAGS_COMMON_GCC) $(CFLAGS_$(1)) -o $$@ $$<
endef

$(foreach a,$(ARCHES),$(eval $(call build_rule,$(a))))

bin/x86_64/$(BIN)-clang: $(SRC) | bin/x86_64
	@printf '[syscall] %-6s %s (clang quality gate)\n' x86_64 $(BIN)
	$(CC_CLANG) $(CFLAGS_COMMON) $(CFLAGS_COMMON_CLANG) $(CFLAGS_x86_64) -o $@ $<

$(foreach a,$(ARCHES),$(eval bin/$(a):; mkdir -p $$@))

scan:
	@printf '[syscall] clang %s (analyzer)\n' $(SRC)
	clang --analyze -Xanalyzer -analyzer-output=text \
	    $(CFLAGS_COMMON) -Werror -o /dev/null $(SRC)

valgrind: bin/x86_64/$(BIN)-valgrind

bin/x86_64/$(BIN)-valgrind: $(SRC) | bin/x86_64
	@printf '[syscall] %-6s %s (valgrind/glibc)\n' x86_64 $(BIN)
	$(CC_VALGRIND) $(CFLAGS_VALGRIND) -o $@ $<

clean:
	rm -rf bin/
