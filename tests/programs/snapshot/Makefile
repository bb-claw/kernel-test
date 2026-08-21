# Cross-compile snapshot for all 4 kernel-test arches (GCC, shipped).
# Clang quality-gate applies to x86_64 only (musl-clang is a host compiler).
# Called by lib/bootstrap.sh; output injected into initramfs at usr/bin/snapshot.
# /init runs it before the test loop; output written to /tmp/snapshot.txt.

SRC    := snapshot.c
BIN    := snapshot
ARCHES := x86_64 i386 arm64 riscv

CC_x86_64 := musl-gcc
CC_i386   := gcc
CC_arm64  := aarch64-linux-gnu-gcc
CC_riscv  := riscv64-linux-gnu-gcc

CFLAGS_x86_64 := -static
CFLAGS_i386   := -m32 -static
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
                       -Wno-padded
# -Wno-padded: struct utsname is 390 bytes (6 × 65-char fields), not a multiple
# of 4; embedding it in a struct causes implicit padding before int ok. We can't
# control the system struct layout, so suppress rather than paper over it.

CC_CLANG := musl-clang

CC_VALGRIND    := gcc
CFLAGS_VALGRIND := -std=c11 -g -O1 -D_DEFAULT_SOURCE -static \
                   -Wno-declaration-after-statement \
                   -Wno-implicit-function-declaration \
                   -Wall -Wextra -Wpedantic -Werror

.PHONY: all clean fmt valgrind

all: $(foreach a,$(ARCHES),bin/$(a)/$(BIN)) bin/x86_64/$(BIN)-clang

define build_rule
bin/$(1)/$(BIN): $(SRC) | bin/$(1)
	@printf '[snapshot] %-6s %s\n' $(1) $(BIN)
	$(CC_$(1)) $(CFLAGS_COMMON) $(CFLAGS_COMMON_GCC) $(CFLAGS_$(1)) -o $$@ $$<
endef

$(foreach a,$(ARCHES),$(eval $(call build_rule,$(a))))

bin/x86_64/$(BIN)-clang: $(SRC) | bin/x86_64
	@printf '[snapshot] %-6s %s (clang quality gate)\n' x86_64 $(BIN)
	$(CC_CLANG) $(CFLAGS_COMMON) $(CFLAGS_COMMON_CLANG) $(CFLAGS_x86_64) -o $@ $<

$(foreach a,$(ARCHES),$(eval bin/$(a):; mkdir -p $$@))

valgrind: bin/x86_64/$(BIN)-valgrind

bin/x86_64/$(BIN)-valgrind: $(SRC) | bin/x86_64
	@printf '[snapshot] %-6s %s (valgrind/glibc)\n' x86_64 $(BIN)
	$(CC_VALGRIND) $(CFLAGS_VALGRIND) -o $@ $<

fmt:
	clang-format --style=file -i $(SRC)

clean:
	rm -rf bin/
