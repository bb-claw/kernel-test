# kernel-test — Linux -rc kernel test harness
# All commands go through this Makefile.
# Usage: make [target] [VAR=value ...]

# ── User-settable variables ────────────────────────────────────────────────────
KERNEL_TREE        ?= ../linux
STABLE_KERNEL_TREE ?= ~/git/linux-stable
STABLE_RELEASE     ?=
TAG                ?=

# When STABLE_RELEASE is set, use the stable tree automatically.
ifdef STABLE_RELEASE
override KERNEL_TREE := $(STABLE_KERNEL_TREE)
endif

# Expand leading ~ and resolve to an absolute path so git/shell never see '~'.
# 'override' is required because command-line variables suppress ordinary :=.
override KERNEL_TREE := $(abspath $(patsubst ~%,$(HOME)%,$(KERNEL_TREE)))

ARCHS         ?= x86_64 i386
CONFIGS       ?= tinyconfig allnoconfig defconfig kunitconfig kunitrandconfig allmodconfig randconfig rand500config randdefconfig
TIMEOUT       ?= 60
BUILD_TIMEOUT ?= 1200
GCC           ?= gcc
REPORT_DIR    ?= reports
V             ?= 0
NO_FETCH      ?= 0
NO_BUILD      ?= 0
TOYBOX_VERSION ?= 0.8.9
DMESG_LABEL    ?= mainline
LABEL          ?=

# ── Internal variables ─────────────────────────────────────────────────────────
BUILD_DIR := build
CACHE_DIR := cache

# Kernel version: version file written by fetch/checkout; fall back to git.
KERNEL_VERSION := $(shell cat $(BUILD_DIR)/.kernel-version 2>/dev/null \
    || git -C "$(KERNEL_TREE)" describe --exact-match HEAD 2>/dev/null \
    || git -C "$(KERNEL_TREE)" rev-parse --short HEAD 2>/dev/null \
    || echo unknown)

# Configs that are built but not booted:
#   allmodconfig — boot impractical: sanitizers + built-in self-tests take 100+ s; modules not in initramfs
#   randconfig   — random config, boot result unpredictable; value is in build coverage
# kunitconfig/kunitrandconfig use defconfig base (already bootable); tinyconfig/allnoconfig/rand500config
# need their configs/<name>.config fragments to restore the TTY/serial/initramfs options they strip.
BUILD_ONLY_CONFIGS := allmodconfig randconfig
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
export TIMEOUT BUILD_TIMEOUT GCC REPORT_DIR V RUN_STAMP NO_FETCH NO_BUILD
export STABLE_RELEASE STABLE_KERNEL_TREE
export TOYBOX_VERSION LABEL

# ── Shell ─────────────────────────────────────────────────────────────────────
SHELL := /bin/bash

# ── Verbosity ─────────────────────────────────────────────────────────────────
ifeq ($(V),1)
  Q :=
else
  Q := @
endif

# ── Phony targets ─────────────────────────────────────────────────────────────
.PHONY: all fetch build initramfs test report diff baseline install dmesg clean distclean bootstrap hooks info checkout help

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

hooks:
	@git config core.hooksPath .githooks
	@echo "[hooks] Git hooks activated (pre-commit, commit-msg, pre-push)"

# ── Kernel tree inspection ────────────────────────────────────────────────────

# Show the current tag/commit checked out in KERNEL_TREE.
info:
	@printf 'Kernel tree:  %s\n' "$(KERNEL_TREE)"
	@printf 'HEAD commit:  %s\n' \
	    "$$(git -C "$(KERNEL_TREE)" rev-parse HEAD 2>/dev/null || echo '(git error — is KERNEL_TREE set?)')"
	@tag=$$(git -C "$(KERNEL_TREE)" describe --exact-match HEAD 2>/dev/null) \
	    && printf 'Tag (git):    %s\n' "$$tag" \
	    || printf 'Tag (git):    (not a tagged commit — nearest: %s)\n' \
	        "$$(git -C "$(KERNEL_TREE)" describe HEAD 2>/dev/null || echo '?')"
	@mf="$(KERNEL_TREE)/Makefile"; \
	if [[ -f $$mf ]]; then \
	    _ver=$$(grep -m1 '^VERSION[[:space:]]*='      "$$mf" | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]'); \
	    _pl=$$(grep  -m1 '^PATCHLEVEL[[:space:]]*='   "$$mf" | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]'); \
	    _sl=$$(grep  -m1 '^SUBLEVEL[[:space:]]*='     "$$mf" | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]'); \
	    _ev=$$(grep  -m1 '^EXTRAVERSION[[:space:]]*=' "$$mf" | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]'); \
	    [[ $${_sl:-0} -eq 0 && $$_ev == -rc* ]] \
	        && kmv="v$${_ver}.$${_pl}$${_ev}" \
	        || kmv="v$${_ver}.$${_pl}.$${_sl}$${_ev}"; \
	    printf 'Tag (Makefile): %s  (VERSION=%s PATCHLEVEL=%s SUBLEVEL=%s EXTRAVERSION=%s)\n' \
	        "$$kmv" "$$_ver" "$$_pl" "$$_sl" "$$_ev"; \
	else \
	    printf 'Tag (Makefile): (Makefile not found)\n'; \
	fi
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
# report always runs — even on build or test failure — so there is always an
# artifact to inspect.  The overall exit code reflects build+test failures.
all:
	+@$(MAKE) fetch
	+@rc=0; \
	 $(MAKE) build    || rc=1; \
	 $(MAKE) initramfs || true; \
	 $(MAKE) test     || rc=1; \
	 $(MAKE) report; \
	 exit $$rc

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
ifeq ($(NO_BUILD),1)
	@echo "[build] Skipping (NO_BUILD=1) — using existing build artifacts"
else
	@echo "[build] Kernel: $(KERNEL_VERSION) | Configs: $(CONFIGS) | Archs: $(ARCHS)"
	$(Q)rc=0; \
	for config in $(CONFIGS); do \
		for arch in $(ARCHS); do \
			printf '[build] %-16s %s\n' "$$config" "$$arch"; \
			lib/build.sh "$$config" "$$arch" || rc=1; \
		done; \
	done; \
	exit $$rc
endif

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
# BUILD_ONLY_CONFIGS are excluded (allmodconfig, randconfig).
# File prerequisites trigger auto-build of missing/stale artifacts.
test: $(foreach c,$(BOOT_CONFIGS),$(foreach a,$(ARCHS),build/$(c)-$(a)/build.status)) \
     $(foreach a,$(ARCHS),build/initramfs-$(a).cpio.gz)
	@echo "[test] Kernel: $(KERNEL_VERSION) | Configs: $(BOOT_CONFIGS) | Archs: $(ARCHS)"
	$(Q)rc=0; \
	for config in $(BOOT_CONFIGS); do \
		for arch in $(ARCHS); do \
			bstatus=$$(grep '^STATUS=' "build/$$config-$$arch/build.status" 2>/dev/null | cut -d= -f2); \
			if [[ $$bstatus != PASS ]]; then \
				printf '[test] %-16s %s  SKIP (build %s)\n' "$$config" "$$arch" "$${bstatus:-missing}"; \
				rc=1; \
				continue; \
			fi; \
			printf '[test] %-16s %s\n' "$$config" "$$arch"; \
			lib/vm.sh "$$config" "$$arch" || rc=1; \
		done; \
	done; \
	exit $$rc

report:
	@echo "[report] Writing to $(REPORT_DIR)/"
	$(Q)lib/report.sh

# Compare two report directories for behavioral changes (regressions / fixes).
# Usage: make diff [OLD=reports/...dir...] [NEW=reports/...dir...]
# Without arguments, compares the two most recent runs automatically.
OLD ?=
NEW ?=
diff:
	$(Q)if [[ -z "$(OLD)" && -z "$(NEW)" ]]; then \
	    lib/diff.sh; \
	elif [[ -n "$(OLD)" && -n "$(NEW)" ]]; then \
	    lib/diff.sh "$(OLD)" "$(NEW)"; \
	else \
	    echo "ERROR: diff requires both OLD= and NEW=, or neither" >&2; exit 1; \
	fi

# Pin the latest report dir as the regression baseline.
# Subsequent 'make all' runs will also diff against this baseline.
baseline:
	$(Q)latest=$$(find "$(REPORT_DIR)" -maxdepth 1 -mindepth 1 -type d ! -name baseline \
	    | sort | tail -1); \
	[[ -n $$latest ]] || { echo "ERROR: no runs found in $(REPORT_DIR)/ — run make all first" >&2; exit 1; }; \
	ln -sfn "$$(basename $$latest)" "$(REPORT_DIR)/baseline"; \
	echo "[baseline] Pinned: $$latest → $(REPORT_DIR)/baseline"

# Capture dmesg from the running host kernel, run analysis, and diff vs previous.
# Usage: make dmesg [DMESG_LABEL=mainline|stable|longterm|linux-next]
dmesg:
	$(Q)lib/dmesg.sh "$(DMESG_LABEL)"

# Install built kernel(s) to /boot and update mkinitcpio + GRUB.
# Designed for daily-driver use with CONFIGS=localconfig ARCHS=x86_64.
# Runs olddefconfig (handles version-change config drift), builds modules
# (fast — reuses ccache), runs dkms autoinstall for out-of-tree modules
# (nvidia, vbox, …), then needs sudo for /boot writes.
install:
	@echo "[install] Config: $(CONFIGS) | Arch: $(ARCHS)"
	$(Q)for config in $(CONFIGS); do \
		for arch in $(ARCHS); do \
			printf '[install] %-16s %s\n' "$$config" "$$arch"; \
			lib/install.sh "$$config" "$$arch"; \
		done; \
	done

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
  bootstrap    Install all build and test dependencies (distro-aware, needs sudo); activates git hooks
  hooks        Activate git hooks only (no package install)
  all          Full pipeline: fetch → build → initramfs → test → report  [default]
  fetch        Fetch and checkout the latest -rc tag automatically
  checkout     Fetch and checkout a specific tag or commit  (requires TAG=)
  info         Show current tag/commit checked out in KERNEL_TREE
  build        Build kernels for all CONFIGS × ARCHS
  initramfs    Assemble Toybox cpio initramfs for each arch
  test         Boot each (config, arch) in QEMU/KVM and run tests
  report       Generate HTML/text report; exits 1 when OVERALL=FAIL (any build/boot/test/mismatch failure)
  diff         Compare two report dirs for regressions/fixes; auto-detects latest two if OLD=/NEW= omitted
  baseline     Pin the latest report dir as the regression baseline; auto-diff will compare against it
  install      Install built kernel to /boot; olddefconfig + SHA256 refresh + dkms autoinstall + mkinitcpio + GRUB; warns if kernel untested (needs sudo, x86_64 only)
  dmesg        Capture host kernel dmesg, analyse errors/hardware, diff vs previous (writes dmesg/)
  clean        Remove build/ and cache/
  distclean    Remove build/, cache/, and reports/
  help         Show this message

Config profiles (CONFIGS=):
  defconfig        Boot+test  Architecture default — broad baseline coverage
  tinyconfig       Boot+test  Minimal kernel — tests lower bound of functionality
  allnoconfig      Boot+test  Everything disabled — absolute minimum boot path
  kunitconfig      Boot+test  defconfig + KUnit framework; KTAP results shown as kunit:N/N
  kunitrandconfig  Boot+test  defconfig + all available KUnit test modules (random set per run); requires rebuild each run
  rand500config    Boot+test  tinyconfig + 500 random =y options (constrained, reproducibly bootable)
  randdefconfig    Boot+test  defconfig with 300 randomly disabled options; heavy subsystems forced off
  localconfig      Boot+test  /proc/config.gz base (running kernel); daily-driver; not in default CONFIGS
  allmodconfig     Build only All options as modules — catches build-time regressions
  randconfig       Build only Fully random config — catches compile-time regressions (BUILD_TIMEOUT capped)

Variables (current values):
  KERNEL_TREE         = $(KERNEL_TREE)
  STABLE_KERNEL_TREE  = $(STABLE_KERNEL_TREE)  (used when STABLE_RELEASE is set)
  STABLE_RELEASE      = $(if $(STABLE_RELEASE),$(STABLE_RELEASE),(not set — mainline rc mode))
  TAG                 = $(if $(TAG),$(TAG),(not set — used by: make checkout TAG=v7.2-rc2))
  ARCHS               = $(ARCHS)
  CONFIGS             = $(CONFIGS)
  TIMEOUT             = $(TIMEOUT)s    (VM boot timeout per config)
  BUILD_TIMEOUT       = $(BUILD_TIMEOUT)s  (per-kernel build timeout; 0 = no limit — use for localconfig; defconfig/kunitconfig x86_64 needs ~10–12 min)
  GCC                 = $(GCC)  (compiler binary; e.g. GCC=gcc-15 for stable kernels that predate GCC 16)
  REPORT_DIR          = $(REPORT_DIR)
  V                   = $(V)  (set to 1 for verbose output)
  NO_FETCH            = $(NO_FETCH)  (set to 1 to skip git fetch and use local tags)
  NO_BUILD            = $(NO_BUILD)  (set to 1 to skip kernel build and use existing build artifacts)
  TOYBOX_VERSION      = $(TOYBOX_VERSION)  (Toybox release pinned in cache/toybox-{x86_64,i686,aarch64})
  DMESG_LABEL         = $(DMESG_LABEL)  (label for make dmesg: mainline/stable/longterm/linux-next)
  LABEL               = $(if $(LABEL),$(LABEL),(auto: STABLE_RELEASE→stable, linux-next tree→linux-next, vX.Y.Z→stable, else mainline))  (report dir prefix; set LABEL=longterm to override)

Note: always use 'make all NO_FETCH=1 ...' rather than chaining 'build test report'
  individually — chaining stops at the first failure, so tests and the report
  are skipped when any build fails. 'make all' continues through all stages and
  always writes a report; the test loop automatically skips configs that did not build.

Note: run 'make clean' when switching between kernel trees (e.g. mainline → stable
  or stable → mainline). Build directories contain generated headers tied to the
  source tree they were built from; reusing them across trees causes subtle mismatches.

Common workflows:

  # New mainline rc announced (e.g. v7.2-rc3) — auto-fetch and test everything
  make

  # Check what is currently checked out before running
  make info

  # Quick single-arch test (report always written even on failure)
  make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64

  # Fast iteration on test scripts — skip rebuild, repack initramfs and re-run tests
  make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS="x86_64 i386 arm64"

  # Run KUnit tests only (kunit:N/N shown in report Tests column)
  make all NO_FETCH=1 NO_BUILD=1 CONFIGS=kunitconfig ARCHS="x86_64 i386 arm64"

  # arm64 uses TCG (no KVM on x86 host); requires aarch64-linux-gnu-gcc + qemu-system-aarch64
  # Install both with: make bootstrap  (then arm64 works in all ARCHS= invocations above)
  make all NO_FETCH=1 ARCHS="x86_64 i386 arm64"

  # New mainline rc — pin exact version, then test (report always written)
  make checkout TAG=v7.2-rc3 
  make all NO_FETCH=1 

  # Build and install daily-driver kernel (Manjaro base config + laptop hardware fragment)
  # BUILD_TIMEOUT=0 disables the timeout — use for localconfig (larger than defconfig)
  make build   NO_FETCH=1 CONFIGS=localconfig ARCHS=x86_64 BUILD_TIMEOUT=0
  make install            CONFIGS=localconfig ARCHS=x86_64

  # New stable rc announced (e.g. v7.1-rc3) — auto-fetch and test everything
  make KERNEL_TREE=~/git/linux-stable

  # New stable release — auto-fetch latest v7.1.x and test everything
  make STABLE_RELEASE=7.1

  # Stable release with older GCC (e.g. 7.1.x fails on GCC 16 — use GCC=gcc-15)
  make fetch STABLE_RELEASE=7.1
  make all   NO_FETCH=1 STABLE_RELEASE=7.1 GCC=gcc-15

  # New stable release — pin exact version, then test
  make checkout TAG=v7.1.3 STABLE_RELEASE=7.1
  make all NO_FETCH=1 STABLE_RELEASE=7.1

  # Stable localconfig build + install (daily-driver, real hardware)
  make fetch STABLE_RELEASE=7.1
  make build NO_FETCH=1 STABLE_RELEASE=7.1 CONFIGS=localconfig ARCHS=x86_64 BUILD_TIMEOUT=0 GCC=gcc-15
  make install           STABLE_RELEASE=7.1 CONFIGS=localconfig ARCHS=x86_64

  # Verbose output for debugging
  make V=1 KERNEL_TREE=~/git/linux-stable

  # Regression diff — auto-detects two most recent same-label runs
  make diff

  # Diff two specific runs (cross-label diff also supported via explicit paths)
  make diff OLD=reports/mainline-7.2-2026-07-12_10-00-00-v7.2-rc1 NEW=reports/mainline-7.2-2026-07-12_11-00-00-v7.2-rc2

  # Pin current results as baseline; future runs will auto-diff against it
  make baseline

  # Rename old-format report dirs to new label-prefixed format
  bash scripts/migrate-reports.sh          # dry-run — shows what would change
  bash scripts/migrate-reports.sh --apply  # rename dirs + update baseline symlink
endef
export HELP_TEXT

help:
	@echo "$$HELP_TEXT"
