# kernel-test — Linux -rc kernel test harness
# All commands go through this Makefile.
# Usage: make [target] [VAR=value ...]

# ── User-settable variables ────────────────────────────────────────────────────
KERNEL_TREE ?= ../linux
# Expand leading ~ and resolve to an absolute path so git/shell never see '~'.
# 'override' is required because command-line variables suppress ordinary :=.
override KERNEL_TREE := $(abspath $(patsubst ~%,$(HOME)%,$(KERNEL_TREE)))
ARCHS       ?= x86_64 i386
CONFIGS     ?= tinyconfig allnoconfig defconfig allmodconfig
TIMEOUT     ?= 60
REPORT_DIR  ?= reports
V           ?= 0
NO_FETCH    ?= 0
TAG         ?=

# ── Internal variables ─────────────────────────────────────────────────────────
BUILD_DIR := build
CACHE_DIR := cache

# Configs that are built but not booted:
#   allmodconfig — kernel too large for the minimal initramfs
# tinyconfig, allnoconfig, and defconfig are bootable via configs/<name>.config fragments.
BUILD_ONLY_CONFIGS := allmodconfig
BOOT_CONFIGS       := $(filter-out $(BUILD_ONLY_CONFIGS),$(CONFIGS))

# Captured once at parse time; ?= prevents sub-makes from recomputing it
# ?= with $(shell) creates a lazy recursive variable — the shell command would
# re-run on every export, giving each sub-process a different timestamp.
# Use ifndef + := so the time is captured once at parse time; sub-makes
# inherit the already-set value from the environment and skip re-evaluation.
ifndef RUN_STAMP
  RUN_STAMP := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
endif

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
.PHONY: all fetch build initramfs test report clean distclean bootstrap info checkout help

# ── File-producing rules (dependency tracking) ────────────────────────────────
# Make uses these to auto-build missing or stale artifacts before 'test'.
# build.status depends on the kernel Makefile so a fresh 'make fetch' (which
# updates timestamps in the tree) invalidates old build results automatically.

define _build_rule
build/$(1)-$(2)/build.status: $$(KERNEL_TREE)/Makefile
	@printf '[build] %-16s %s\n' $(1) $(2)
	$$(Q)lib/build.sh $(1) $(2)
endef
$(foreach c,$(CONFIGS),$(foreach a,$(ARCHS),$(eval $(call _build_rule,$(c),$(a)))))

define _initramfs_rule
build/initramfs-$(1).cpio.gz:
	@printf '[initramfs] %s\n' $(1)
	$$(Q)lib/initramfs.sh $(1)
endef
$(foreach a,$(ARCHS),$(eval $(call _initramfs_rule,$(a))))

# ── Setup ─────────────────────────────────────────────────────────────────────

bootstrap:
	$(Q)lib/bootstrap.sh

# ── Kernel tree inspection ────────────────────────────────────────────────────

# Show the current tag/commit checked out in KERNEL_TREE.
info:
	@printf 'Kernel tree:  %s\n' "$(KERNEL_TREE)"
	@printf 'HEAD commit:  %s\n' \
	    "$$(git -C "$(KERNEL_TREE)" rev-parse HEAD 2>/dev/null || echo '(git error — is KERNEL_TREE set?)')"
	@tag=$$(git -C "$(KERNEL_TREE)" describe --exact-match HEAD 2>/dev/null) \
	    && printf 'Tag:          %s\n' "$$tag" \
	    || printf 'Tag:          (not a tagged commit — nearest: %s)\n' \
	        "$$(git -C "$(KERNEL_TREE)" describe HEAD 2>/dev/null || echo '?')"
	@[[ -f $(BUILD_DIR)/.kernel-version ]] \
	    && printf 'Version file: %s\n' "$$(cat $(BUILD_DIR)/.kernel-version)" \
	    || printf 'Version file: (not set — run: make fetch  or  make checkout TAG=v7.2-rc2)\n'

# Fetch and checkout a specific tag or commit. Usage: make checkout TAG=v7.2-rc2
checkout:
	$(if $(TAG),,$(error TAG is required — usage: make checkout TAG=v7.2-rc2))
	$(Q)lib/checkout.sh "$(TAG)"

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
# BUILD_ONLY_CONFIGS are excluded (currently: allmodconfig).
# File prerequisites trigger auto-build of missing/stale artifacts.
test: $(foreach c,$(BOOT_CONFIGS),$(foreach a,$(ARCHS),build/$(c)-$(a)/build.status)) \
     $(foreach a,$(ARCHS),build/initramfs-$(a).cpio.gz)
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
  fetch        Fetch and checkout the latest -rc tag automatically
  checkout     Fetch and checkout a specific tag or commit  (requires TAG=)
  info         Show current tag/commit checked out in KERNEL_TREE
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
  TAG          = $(if $(TAG),$(TAG),(not set — used by: make checkout TAG=v7.2-rc2))

Examples:
  make KERNEL_TREE=../linux
  make checkout TAG=v7.2-rc2 KERNEL_TREE=../linux
  make info KERNEL_TREE=../linux
  make build KERNEL_TREE=../linux CONFIGS=defconfig ARCHS=x86_64
  make build initramfs test report NO_FETCH=1 KERNEL_TREE=../linux
  make V=1 KERNEL_TREE=../linux
endef
export HELP_TEXT

help:
	@echo "$$HELP_TEXT"
