# syscall-tests: cross-compiled for all 4 arches.
# -Wno-cast-align:       ring buffer pointer arithmetic (uint32_t * from char *)
# -Wno-shorten-64-to-32: deliberate (int)syscall() on 64-bit hosts
# -Wno-sign-conversion:  mixed signed/unsigned in ring buffer index math
# nolibc: sys/socket.h, sys/eventfd.h, sys/signalfd.h, sys/shm.h etc. absent — keeps musl.

SRC     := syscall-tests.c
BIN     := syscall-tests
LOG_TAG := syscall

CFLAGS_CLANG_EXTRA := -Wno-cast-align -Wno-shorten-64-to-32 -Wno-sign-conversion
CFLAGS_arm64_EXTRA := -Wno-pointer-to-int-cast
CFLAGS_riscv_EXTRA := -Wno-pointer-to-int-cast

include ../common.mk
