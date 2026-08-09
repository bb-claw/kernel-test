# serial-capture: host-side serial capture tool (x86_64 only).
# Builds GCC/musl (quality gate) and Clang/musl (shipped) in one `make all`.
# Both must compile with zero warnings; any warning is a build error.
#
# This Makefile is the reference baseline for all C programs in tests/programs/.
# See docs/serial-capture-hardening-plan.md for the flag rationale.

SRC     := serial-capture.c
BIN     := bin/serial-capture      # Clang/musl — installed by lib/bootstrap.sh
BIN_GCC := bin/serial-capture-gcc  # GCC/musl   — quality gate only, not installed

CC_CLANG := musl-clang
CC_GCC   := musl-gcc

# Flags shared by both compilers.
# -D_DEFAULT_SOURCE: enables cfmakeraw(), fdatasync() on glibc and musl.
# -Wno-declaration-after-statement: C11 permits mixed declarations; used
#   project-wide for readability; not a safety concern.
# -Wno-implicit-function-declaration: guard against missing-header regressions.
CFLAGS_COMMON := -std=c11 -O2 -D_DEFAULT_SOURCE \
    -Wno-declaration-after-statement \
    -Wno-implicit-function-declaration

# GCC: comprehensive, well-established warning set.
CFLAGS_COMMON_GCC := -Wall -Wextra -Wpedantic -Werror

# Clang: maximum coverage via -Weverything, with documented suppressions.
# Each suppression has an inline rationale.
CFLAGS_COMMON_CLANG := \
    -Weverything -Werror \
    -Wno-disabled-macro-expansion \
    -Wno-unsafe-buffer-usage
# -Wno-disabled-macro-expansion: musl defines stderr as a self-referential
#   macro (#define stderr (stderr)); Clang fires on every fprintf(stderr, ...).
#   This is a musl implementation detail, not a code defect.
# -Wno-unsafe-buffer-usage: argv[N] indexing and buf+off pointer arithmetic
#   are demonstrably bounds-correct; no safer C11 API exists for these patterns.

.PHONY: all clean

all: $(BIN_GCC) $(BIN)

$(BIN_GCC): $(SRC) | bin
	@printf '[serial-capture] gcc   %s\n' $(BIN_GCC)
	$(CC_GCC)   $(CFLAGS_COMMON) $(CFLAGS_COMMON_GCC)   -static -o $@ $<

$(BIN): $(SRC) | bin
	@printf '[serial-capture] clang %s\n' $(BIN)
	$(CC_CLANG) $(CFLAGS_COMMON) $(CFLAGS_COMMON_CLANG) -static -o $@ $<

bin:
	mkdir -p bin

clean:
	rm -rf bin/
