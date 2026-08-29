# snapshot: cross-compiled for all 4 arches.
# -Wno-padded: struct utsname (390 bytes) is not a multiple of 4; embedding it
#   in a snapshot_data struct causes implicit padding before int ok. The system
#   struct layout is fixed — suppress rather than paper over it.
# nolibc: sys/klog.h and pwd.h absent from nolibc — keeps musl.

SRC := snapshot.c
BIN := snapshot

CFLAGS_CLANG_EXTRA := -Wno-padded
CFLAGS_arm64_EXTRA := -Wno-pointer-to-int-cast
CFLAGS_riscv_EXTRA := -Wno-pointer-to-int-cast

include ../common.mk
