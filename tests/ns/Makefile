# Cross-compile ns-* test binaries for all 4 kernel-test arches.
# Called unconditionally by lib/bootstrap.sh so binaries are always available.
# Output: bin/<arch>/ns-{uts,ipc,pid,mount,net,user,cgroup,time}

SRCS := ns-uts.c ns-ipc.c ns-pid.c ns-mount.c ns-net.c ns-user.c ns-cgroup.c ns-time.c
BINS := $(SRCS:%.c=%)
ARCHES := x86_64 i386 arm64 riscv

# Per-arch compiler + flags
CC_x86_64  := gcc
CC_i386    := gcc
CC_arm64   := aarch64-linux-gnu-gcc
CC_riscv   := riscv64-linux-gnu-gcc

CFLAGS_x86_64 := -static -O2 -Wall
CFLAGS_i386   := -m32 -static -O2 -Wall
CFLAGS_arm64  := -static -O2 -Wall
CFLAGS_riscv  := -static -O2 -Wall

CFLAGS_COMMON := -std=gnu11

.PHONY: all clean

all: $(foreach a,$(ARCHES),$(foreach b,$(BINS),bin/$(a)/$(b)))

# Generic rule: bin/<arch>/<binary>: <binary>.c
define build_rule
bin/$(1)/$(2): $(2).c | bin/$(1)
	@printf '[ns] %-6s %s\n' $(1) $(2)
	$(CC_$(1)) $(CFLAGS_COMMON) $(CFLAGS_$(1)) -o $$@ $$<
endef

$(foreach a,$(ARCHES),$(foreach b,$(BINS),$(eval $(call build_rule,$(a),$(b)))))

# Directory targets
$(foreach a,$(ARCHES),$(eval bin/$(a):; mkdir -p $$@))

clean:
	rm -rf bin/
