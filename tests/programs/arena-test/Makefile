# arena-test: cross-compiled for all 4 arches; nolibc for x86_64 GCC build.
# x86_64: plain gcc + kernel nolibc headers (no musl-gcc dependency).
# arm64/riscv: cross-gcc; -Wno-pointer-to-int-cast silences spurious cast warning.
# Clang quality gate (x86_64): musl-clang (unchanged; nolibc + musl-clang requires
#   a new suppression for -static-libgcc under -nostdlib — rejected per criteria).

SRC := arena-test.c
BIN := arena-test

REPO        := $(abspath $(CURDIR)/../../..)
KERNEL_TREE ?= $(REPO)/../linux
CC_x86_64   := gcc
CFLAGS_x86_64_EXTRA := -nostdlib \
    -isystem $(KERNEL_TREE)/tools/include/nolibc \
    -include nolibc.h \
    -mstack-protector-guard=global

CFLAGS_arm64_EXTRA := -Wno-pointer-to-int-cast
CFLAGS_riscv_EXTRA := -Wno-pointer-to-int-cast

include ../common.mk
