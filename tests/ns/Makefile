# Cross-compile ns-* test binaries for all 4 kernel-test arches.
# Called unconditionally by lib/bootstrap.sh so binaries are always available.
# Output: bin/<arch>/ns-{uts,ipc,pid,mount,net,user,cgroup,time}
# Quality: same C17 + extended warning set + Clang gate as tests/programs/.

SRCS  := ns-uts.c ns-ipc.c ns-pid.c ns-mount.c ns-net.c ns-user.c ns-cgroup.c ns-time.c
BINS  := $(SRCS:%.c=%)
ARCHES := x86_64 i386 arm64 riscv

# Import shared compiler + flag variables; no build rules (multi-binary layout).
FLAGS_ONLY := 1
include ../programs/common.mk

.PHONY: all clean

all: $(foreach a,$(ARCHES),$(foreach b,$(BINS),bin/$(a)/$(b))) \
     $(foreach b,$(BINS),bin/x86_64/$(b)-clang)

define build_rule
bin/$(1)/$(2): $(2).c | bin/$(1)
	@printf '[ns] %-6s %s\n' $(1) $(2)
	$(CC_$(1)) $(CFLAGS_COMMON) $(CFLAGS_GCC) $(CFLAGS_$(1)) $(CFLAGS_$(1)_EXTRA) -o $$@ $$<
endef

$(foreach a,$(ARCHES),$(foreach b,$(BINS),$(eval $(call build_rule,$(a),$(b)))))

define build_rule_clang
bin/x86_64/$(1)-clang: $(1).c | bin/x86_64
	@printf '[ns]  %-6s %s (clang quality gate)\n' x86_64 $(1)
	$(CC_CLANG) $(CFLAGS_COMMON) $(CFLAGS_CLANG) $(CFLAGS_CLANG_EXTRA) $(CFLAGS_x86_64) -o $$@ $$<
endef

$(foreach b,$(BINS),$(eval $(call build_rule_clang,$(b))))

$(foreach a,$(ARCHES),$(eval bin/$(a):; mkdir -p $$@))

clean:
	rm -rf bin/
