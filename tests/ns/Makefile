# Cross-compile ns-* test binaries for all 4 kernel-test arches.
# Called unconditionally by lib/bootstrap.sh so binaries are always available.
# Output: bin/<arch>/ns-{uts,ipc,pid,mount,net,user,cgroup,time}
# Quality: same C17 + extended warning set + GCC + Clang gates as tests/programs/.

SRCS  := ns-uts.c ns-ipc.c ns-pid.c ns-mount.c ns-net.c ns-user.c ns-cgroup.c ns-time.c
BINS  := $(SRCS:%.c=%)
ARCHES := x86_64 i386 arm64 riscv

# Import shared compiler + flag variables; no build rules (multi-binary layout).
FLAGS_ONLY := 1
include ../common.mk

.PHONY: all clean valgrind valgrind-build

all: $(foreach a,$(ARCHES),$(foreach b,$(BINS),bin/$(a)/$(b))) \
     $(foreach b,$(BINS),bin/x86_64/$(b)-gcc) \
     $(foreach b,$(BINS),bin/x86_64/$(b)-clang)

define build_rule
bin/$(1)/$(2): $(2).c | bin/$(1)
	@printf '[ns] %-6s %s\n' $(1) $(2)
	$(CC_$(1)) $(CFLAGS_COMMON) $(CFLAGS_GCC) $(CFLAGS_$(1)) $(CFLAGS_$(1)_EXTRA) -o $$@ $$<
endef

$(foreach a,$(ARCHES),$(foreach b,$(BINS),$(eval $(call build_rule,$(a),$(b)))))

define build_rule_gcc
bin/x86_64/$(1)-gcc: $(1).c | bin/x86_64
	@printf '[ns]  %-6s %s (gcc quality gate)\n' x86_64 $(1)
	$(CC_x86_64) $(CFLAGS_COMMON) $(CFLAGS_GCC) $(CFLAGS_GCC_EXTRA) $(CFLAGS_x86_64) -o $$@ $$<
endef

$(foreach b,$(BINS),$(eval $(call build_rule_gcc,$(b))))

define build_rule_clang
bin/x86_64/$(1)-clang: $(1).c | bin/x86_64
	@printf '[ns]  %-6s %s (clang quality gate)\n' x86_64 $(1)
	$(CC_CLANG) $(CFLAGS_COMMON) $(CFLAGS_CLANG) $(CFLAGS_CLANG_EXTRA) $(CFLAGS_x86_64) -o $$@ $$<
endef

$(foreach b,$(BINS),$(eval $(call build_rule_clang,$(b))))

$(foreach a,$(ARCHES),$(eval bin/$(a):; mkdir -p $$@))

define valgrind_rule
bin/x86_64/$(1)-valgrind: $(1).c | bin/x86_64
	@printf '[ns]  %-6s %s (valgrind/glibc)\n' x86_64 $(1)
	$(CC_VALGRIND) $(CFLAGS_VALGRIND_FLAGS) $(CFLAGS_GCC_EXTRA) -o $$@ $$<
endef

$(foreach b,$(BINS),$(eval $(call valgrind_rule,$(b))))

valgrind-build: $(foreach b,$(BINS),bin/x86_64/$(b)-valgrind)

# VG uses the shared suppression file from tests/programs/.
# _TESTS_DIR (tests/) is set by the common.mk include above.
VG := valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=all \
      --errors-for-leak-kinds=all --track-origins=yes --track-fds=yes \
      --suppressions=$(_TESTS_DIR)programs/valgrind.supp

# Exit 99 = valgrind memory error → fail. Any other non-zero = EPERM/ENOSYS → skip.
define run_ns
	$(VG) bin/x86_64/$(1)-valgrind $(2) || { rc=$$?; [ $$rc -ne 99 ] || exit 1; }
endef

# ns-uts setns requires a live namespace path argument — skipped here.
valgrind: valgrind-build
	$(call run_ns,ns-uts,clone)
	$(call run_ns,ns-ipc,clone)
	$(call run_ns,ns-ipc,semop)
	$(call run_ns,ns-pid,clone)
	$(call run_ns,ns-pid,init-death)
	$(call run_ns,ns-mount,move)
	$(call run_ns,ns-mount,mknod)
	$(call run_ns,ns-mount,propagate)
	$(call run_ns,ns-mount,pivot)
	$(call run_ns,ns-net,clone)
	$(call run_ns,ns-net,proc-net)
	$(call run_ns,ns-user,idmap)
	$(call run_ns,ns-user,nested-6)
	$(call run_ns,ns-cgroup,scoping)
	$(call run_ns,ns-cgroup,release-agent)
	$(call run_ns,ns-time,offset)
	$(call run_ns,ns-time,setns-mt)

clean:
	rm -rf bin/
