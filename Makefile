# kernel-test — Linux -rc kernel test harness
# All commands go through this Makefile.
# Usage: make [target] [VAR=value ...]

# ── User-settable variables ────────────────────────────────────────────────────
KERNEL_TREE ?= ../linux
ARCHS       ?= x86_64 i386
CONFIGS     ?= tinyconfig allnoconfig defconfig allmodconfig
TIMEOUT     ?= 60
REPORT_DIR  ?= reports
V           ?= 0
NO_FETCH    ?= 0

# ── Internal variables ─────────────────────────────────────────────────────────
BUILD_DIR := build
CACHE_DIR := cache

# Configs that are built but not booted:
#   allmodconfig — kernel too large for the minimal initramfs
#   tinyconfig   — disables PRINTK, TTY, SERIAL, BLK_DEV_INITRD; boots silently forever
#   allnoconfig  — even more stripped than tinyconfig; same problem
# To boot a minimal kernel add a fragment: make CONFIGS=tinyboot (see configs/)
BUILD_ONLY_CONFIGS := allmodconfig tinyconfig allnoconfig
BOOT_CONFIGS       := $(filter-out $(BUILD_ONLY_CONFIGS),$(CONFIGS))

# Captured once at parse time; ?= prevents sub-makes from recomputing it
RUN_STAMP ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Exports (inherited by lib scripts as environment variables) ────────────────
export KERNEL_TREE BUILD_DIR CACHE_DIR
export ARCHS CONFIGS BOOT_CONFIGS BUILD_ONLY_CONFIGS
export TIMEOUT REPORT_DIR V RUN_STAMP NO_FETCH

# ── Shell ─────────────────────────────────────────────────────────────────────
SHELL := /bin/bash

# ── Verbosity ─────────────────────────────────────────────────────────────────
ifeq ($(V),1)
  Q :=
else
  Q := @
endif

# ── Phony targets ─────────────────────────────────────────────────────────────
.PHONY: all fetch build initramfs test report clean distclean bootstrap help

# ── Setup ─────────────────────────────────────────────────────────────────────

bootstrap:
	$(Q)lib/bootstrap.sh

# ── Default: full pipeline ────────────────────────────────────────────────────
# Sub-make calls guarantee sequential execution even under make -j.
# The exported RUN_STAMP is inherited, so all stages share one timestamp.
all:
	+@$(MAKE) fetch
	+@$(MAKE) build
	+@$(MAKE) initramfs
	+@$(MAKE) test
	+@$(MAKE) report

# ── Pipeline stages ───────────────────────────────────────────────────────────

fetch:
ifeq ($(NO_FETCH),1)
	@echo "[fetch] Skipping (NO_FETCH=1) — using existing local tag"
else
	@echo "[fetch] Fetching latest -rc tag from $(KERNEL_TREE)"
	$(Q)lib/fetch.sh
endif

# Build all CONFIGS × ARCHS; collect failures and exit non-zero if any failed.
# allmodconfig is included here (build only, not booted).
build:
	@echo "[build] Configs: $(CONFIGS) | Archs: $(ARCHS)"
	$(Q)rc=0; \
	for config in $(CONFIGS); do \
		for arch in $(ARCHS); do \
			printf '[build] %-16s %s\n' "$$config" "$$arch"; \
			lib/build.sh "$$config" "$$arch" || rc=1; \
		done; \
	done; \
	exit $$rc

# Build one initramfs per arch (shared across config variants).
initramfs:
	@echo "[initramfs] Archs: $(ARCHS)"
	$(Q)rc=0; \
	for arch in $(ARCHS); do \
		printf '[initramfs] %s\n' "$$arch"; \
		lib/initramfs.sh "$$arch" || rc=1; \
	done; \
	exit $$rc

# Boot BOOT_CONFIGS × ARCHS in QEMU/KVM and run tests.
# allmodconfig is excluded (BUILD_ONLY_CONFIGS).
test:
	@echo "[test] Configs: $(BOOT_CONFIGS) | Archs: $(ARCHS)"
	$(Q)rc=0; \
	for config in $(BOOT_CONFIGS); do \
		for arch in $(ARCHS); do \
			printf '[test] %-16s %s\n' "$$config" "$$arch"; \
			lib/vm.sh "$$config" "$$arch" || rc=1; \
		done; \
	done; \
	exit $$rc

report:
	@echo "[report] Writing to $(REPORT_DIR)/"
	$(Q)lib/report.sh

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean:
	@echo "[clean] Removing $(BUILD_DIR)/ $(CACHE_DIR)/"
	$(Q)rm -rf $(BUILD_DIR) $(CACHE_DIR)

distclean: clean
	@echo "[distclean] Removing $(REPORT_DIR)/"
	$(Q)rm -rf $(REPORT_DIR)

# ── Help ──────────────────────────────────────────────────────────────────────

define HELP_TEXT
kernel-test — Linux -rc kernel test harness

Targets:
  bootstrap    Install all build and test dependencies (distro-aware, needs sudo)
  all          Full pipeline: fetch → build → initramfs → test → report  [default]
  fetch        Fetch and checkout the latest -rc tag
  build        Build kernels for all CONFIGS × ARCHS
  initramfs    Assemble BusyBox cpio initramfs for each arch
  test         Boot each (config, arch) in QEMU/KVM and run tests
  report       Generate HTML and plain-text report from last test run
  clean        Remove build/ and cache/
  distclean    Remove build/, cache/, and reports/
  help         Show this message

Variables (current values):
  KERNEL_TREE  = $(KERNEL_TREE)
  ARCHS        = $(ARCHS)
  CONFIGS      = $(CONFIGS)
  TIMEOUT      = $(TIMEOUT)s
  REPORT_DIR   = $(REPORT_DIR)
  V            = $(V)  (set to 1 for verbose output)
  NO_FETCH     = $(NO_FETCH)  (set to 1 to skip git fetch and use local tags)

Examples:
  make KERNEL_TREE=../linux
  make build KERNEL_TREE=../linux CONFIGS=defconfig ARCHS=x86_64
  make build initramfs test report KERNEL_TREE=../linux
  make V=1 KERNEL_TREE=../linux
endef
export HELP_TEXT

help:
	@echo "$$HELP_TEXT"
