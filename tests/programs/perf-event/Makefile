# Cross-compile perf-event binary for all 4 kernel-test arches.
# Called by lib/bootstrap.sh; output injected into initramfs at usr/bin/perf-event.

SRC    := perf-event.c
BIN    := perf-event
ARCHES := x86_64 i386 arm64 riscv

CC_x86_64 := gcc
CC_i386   := gcc
CC_arm64  := aarch64-linux-gnu-gcc
CC_riscv  := riscv64-linux-gnu-gcc

CFLAGS_x86_64 := -static -O2 -Wall
CFLAGS_i386   := -m32 -static -O2 -Wall
CFLAGS_arm64  := -static -O2 -Wall
CFLAGS_riscv  := -static -O2 -Wall

CFLAGS_COMMON := -std=gnu11

.PHONY: all clean

all: $(foreach a,$(ARCHES),bin/$(a)/$(BIN))

define build_rule
bin/$(1)/$(BIN): $(SRC) | bin/$(1)
	@printf '[perf] %-6s %s\n' $(1) $(BIN)
	$(CC_$(1)) $(CFLAGS_COMMON) $(CFLAGS_$(1)) -o $$@ $$<
endef

$(foreach a,$(ARCHES),$(eval $(call build_rule,$(a))))

$(foreach a,$(ARCHES),$(eval bin/$(a):; mkdir -p $$@))

clean:
	rm -rf bin/
