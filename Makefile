# kernel-test — Linux -rc kernel test harness
# All commands go through this Makefile.
# Usage: make [target] [VAR=value ...]

# ── Repo preset (auto) + user override ────────────────────────────────────────
# Preset selected by directory name — works immediately after clone, no setup needed.
# NOTE: renaming the clone directory breaks preset detection (no error, variables silently unset).
# local.mk (gitignored) is included after the preset for machine-local overrides.
REPO_DIR := $(notdir $(CURDIR))
-include presets/$(REPO_DIR).mk
-include local.mk

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

ARCHS         ?= x86_64 i386 arm64
CONFIGS       ?= tinyconfig allnoconfig defconfig kunitconfig kunitrandconfig allmodconfig randconfig rand500config randdefconfig
TIMEOUT       ?= 60
BUILD_TIMEOUT ?= 1200
GCC           ?= gcc
REPORT_DIR    ?= reports
V             ?= 0
NO_FETCH      ?= 0
NO_BUILD      ?= 0
LINUX_NEXT    ?= 0
TOYBOX_VERSION ?= 0.8.9
DMESG_LABEL    ?= mainline
LABEL          ?=
CONFIG_FILE    ?=
SEED_CONFIG    ?=
SUBSYSTEM      ?=
DRIVER         ?=
VERIFY         ?= 0
DRY_RUN        ?= 0
PASS2          ?= 0
SKIP_CFGS      ?=
GATE_CFGS      ?=

# ── Internal variables ─────────────────────────────────────────────────────────
BUILD_DIR := build
CACHE_DIR := cache

# Kernel version: version file written by fetch/checkout; fall back to git then kernel Makefile.
KERNEL_VERSION := $(shell cat $(BUILD_DIR)/.kernel-version 2>/dev/null \
    || git -C "$(KERNEL_TREE)" describe --exact-match HEAD 2>/dev/null \
    || make -s -C "$(KERNEL_TREE)" kernelversion 2>/dev/null \
    || git -C "$(KERNEL_TREE)" rev-parse --short HEAD 2>/dev/null \
    || echo unknown)

# Configs that are built but not booted:
#   allmodconfig    — boot impractical: sanitizers + built-in self-tests take 100+ s; modules not in initramfs
#   randconfig      — random config, boot result unpredictable; value is in build coverage
# kunitrandconfig is booted: defconfig base is bootable; KUnit emits KTAP to serial; KUNIT_PASS/FAIL tracked.
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
export STABLE_RELEASE STABLE_KERNEL_TREE STABLE_RC_BRANCH LINUX_NEXT
export TOYBOX_VERSION LABEL
export SEED_CONFIG
export SUBSYSTEM DRIVER VERIFY DRY_RUN PASS2 SKIP_CFGS GATE_CFGS

# ── Shell ─────────────────────────────────────────────────────────────────────
SHELL := /bin/bash

# ── Verbosity ─────────────────────────────────────────────────────────────────
ifeq ($(V),1)
  Q :=
else
  Q := @
endif

# ── Phony targets ─────────────────────────────────────────────────────────────
.PHONY: all smoke full local fetch fetch-stable fetch-stable-rc fetch-next build initramfs test report diff baseline install dmesg clean distclean bootstrap hooks info checkout config-archive replay kconfig-check kconfig-build bisect help

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
	    || printf 'Version file: (not set — run: make fetch / make fetch-stable / make fetch-stable-rc  or  make checkout TAG=)\n'

# Fetch and checkout a specific tag or commit. Usage: make checkout TAG=v7.2-rc2
checkout:
	$(if $(TAG),,$(error TAG is required — usage: make checkout TAG=v7.2-rc2))
	$(Q)lib/checkout.sh "$(TAG)"

# ── Convenience targets ───────────────────────────────────────────────────────

# presets/<dir>.mk supplies repo-specific params (STABLE_RELEASE, KERNEL_TREE, LABEL, GCC, …).
smoke:
	+@$(MAKE) all NO_FETCH=1 CONFIGS="kunitconfig tinyconfig"

full:
	+@$(MAKE) all NO_FETCH=1 CONFIGS="kunitconfig tinyconfig defconfig randdefconfig rand500config"

# Daily-driver build: localconfig x86_64 only (uses /proc/config.gz; no BUILD_TIMEOUT).
local:
	+@$(MAKE) all NO_FETCH=1 CONFIGS=localconfig ARCHS=x86_64 BUILD_TIMEOUT=0

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

# Auto-dispatch based on preset variables:
#   LINUX_NEXT=1         → error: use make fetch-next  (lib/fetch-next.sh)
#   STABLE_RC_BRANCH set → stable-rc branch fetch      (lib/fetch-stable-rc.sh)
#   STABLE_RELEASE set   → stable tag fetch             (lib/fetch.sh)
#   neither set          → mainline rc tag fetch        (lib/fetch.sh)
# Presets set these automatically based on the clone directory name.
fetch:
ifeq ($(NO_FETCH),1)
	@echo "[fetch] Skipping (NO_FETCH=1) — using existing local state"
else ifeq ($(LINUX_NEXT),1)
	$(error [fetch] linux-next does not use rc tags — use: make fetch-next)
else ifneq ($(STABLE_RC_BRANCH),)
	@echo "[fetch] stable-rc: fetching branch $(STABLE_RC_BRANCH) from $(KERNEL_TREE)"
	$(Q)lib/fetch-stable-rc.sh
else ifneq ($(STABLE_RELEASE),)
	@echo "[fetch] stable: fetching latest $(STABLE_RELEASE).y tag from $(KERNEL_TREE)"
	$(Q)lib/fetch.sh
else
	@echo "[fetch] mainline: fetching latest -rc tag from $(KERNEL_TREE)"
	$(Q)lib/fetch.sh
endif

# Explicit override targets — useful when running outside the preset-managed clones.
fetch-stable:
ifeq ($(NO_FETCH),1)
	@echo "[fetch-stable] Skipping (NO_FETCH=1) — using existing local tag"
else
	$(if $(STABLE_RELEASE),,$(error STABLE_RELEASE is required — usage: make fetch-stable STABLE_RELEASE=7.1))
	@echo "[fetch-stable] Fetching latest $(STABLE_RELEASE).y tag from $(KERNEL_TREE)"
	$(Q)lib/fetch.sh
endif

fetch-stable-rc:
ifeq ($(NO_FETCH),1)
	@echo "[fetch-stable-rc] Skipping (NO_FETCH=1) — using existing local state"
else
	$(if $(STABLE_RC_BRANCH),,$(error STABLE_RC_BRANCH is required — set it in presets/ or pass STABLE_RC_BRANCH=linux-7.1.y))
	@echo "[fetch-stable-rc] Fetching branch $(STABLE_RC_BRANCH) from $(KERNEL_TREE)"
	$(Q)lib/fetch-stable-rc.sh
endif

fetch-next:
ifeq ($(NO_FETCH),1)
	@echo "[fetch-next] Skipping (NO_FETCH=1) — using existing local state"
else
	$(if $(filter 1,$(LINUX_NEXT)),,$(error LINUX_NEXT=1 is required — set it in presets/kernel-test-next.mk or pass LINUX_NEXT=1))
	@echo "[fetch-next] Fetching origin/master from linux-next tree $(KERNEL_TREE)"
	$(Q)lib/fetch-next.sh
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

# ── Config archive ────────────────────────────────────────────────────────────

# Scan all report directories and populate configs/archive_passed/ and
# configs/archive_failed/ with deduplicated config files.
# Deduplicates by SHA256; a config that ever produced PASS goes to archive_passed/
# even if it also failed in other runs.
config-archive:
	$(Q)scripts/config-archive.sh

# ── Kconfig static analysis ───────────────────────────────────────────────────

# Scan a kernel subsystem for missing 'select' dependencies.
# Usage: make kconfig-check SUBSYSTEM=pinctrl [VERIFY=1] [ARCHS=arm64] [DRIVER=pinctrl-bm1880] [PASS2=1] [SKIP_CFGS=CONFIG_DEBUG_FS,CONFIG_PM] [GATE_CFGS=CONFIG_GPIOLIB]
kconfig-check:
	@test -n "$(SUBSYSTEM)" || { echo "ERROR: SUBSYSTEM= is required — usage: make kconfig-check SUBSYSTEM=<name>"; exit 1; }
	$(Q)ARCH=$(firstword $(ARCHS)) scripts/kconfig-check.sh "$(SUBSYSTEM)"

# Exhaustive per-option build+boot sweep for a kernel subsystem.
# Enumerates all config entries in drivers/<SUBSYSTEM>/Kconfig and builds+boots each.
# Usage: make kconfig-build SUBSYSTEM=pinctrl [ARCHS=arm64] [DRY_RUN=1] [GATE_CFGS=CONFIG_X]
kconfig-build:
	@test -n "$(SUBSYSTEM)" || { echo "ERROR: SUBSYSTEM= is required — usage: make kconfig-build SUBSYSTEM=<name>"; exit 1; }
	$(Q)lib/build-kconfig.sh

# ── Replay archived config ────────────────────────────────────────────────────

# Replay an archived config file through the full pipeline.
# Parses config + arch from the archive filename, warns on kernel version mismatch,
# then delegates to 'make all NO_FETCH=1' with SEED_CONFIG set.
# Usage: make replay CONFIG_FILE=configs/archive_passed/kconfig-tinyconfig-x86_64-v7.2-rc2-<sha256>.config
replay:
	@if [[ -z "$(CONFIG_FILE)" ]]; then \
	    echo "ERROR: CONFIG_FILE= is required."; \
	    echo "  make replay CONFIG_FILE=configs/archive_passed/kconfig-<config>-<arch>-<version>-<sha256>.config"; \
	    exit 1; \
	fi; \
	base=$$(basename "$(CONFIG_FILE)" .config); \
	rest=$${base#kconfig-}; \
	config=""; arch=""; \
	for arch_try in x86_64 i386 arm64; do \
	    if [[ "$$rest" == *"-$$arch_try-"* ]]; then \
	        config=$${rest%%-$$arch_try-*}; \
	        arch=$$arch_try; \
	        break; \
	    fi; \
	done; \
	if [[ -z "$$config" || -z "$$arch" ]]; then \
	    echo "ERROR: Cannot parse config/arch from filename: $$base"; \
	    exit 1; \
	fi; \
	after=$${rest#$$config-$$arch-}; \
	sha=$$(grep -oE '[0-9a-f]{64}' <<< "$$after" | head -1); \
	version=$${after%%-$$sha*}; \
	if [[ -n "$$version" && "$$version" != "$(KERNEL_VERSION)" ]]; then \
	    echo "WARN: archived config is from $$version; current kernel is $(KERNEL_VERSION)"; \
	fi; \
	seed=$$(realpath "$(CONFIG_FILE)"); \
	echo "[replay] config=$$config arch=$$arch version=$$version seed=$$seed"; \
	$(MAKE) all NO_FETCH=1 CONFIGS="$$config" ARCHS="$$arch" SEED_CONFIG="$$seed"

# Binary-search a failing archived config to isolate the responsible option(s).
# Produces a minimal reproducer config and a draft FINDINGS.md entry.
# Usage: make bisect CONFIG_FILE=configs/archive_failed/kconfig-<config>-<arch>-...-BOOT_FAIL-*.config
#        make bisect CONFIG_FILE=<path> DRY_RUN=1     # preview plan without building
bisect:
	@if [[ -z "$(CONFIG_FILE)" ]]; then \
	    echo "ERROR: CONFIG_FILE= is required."; \
	    echo "  make bisect CONFIG_FILE=configs/archive_failed/kconfig-<config>-<arch>-<version>-<sha256>-<FAILURE>.config"; \
	    exit 1; \
	fi
	$(Q)CONFIG_FILE="$(CONFIG_FILE)" DRY_RUN="$(DRY_RUN)" PINNED_OPTS="$(PINNED_OPTS)" \
	    scripts/config-bisect.sh

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
  bootstrap        Install all build and test dependencies (distro-aware, needs sudo); activates git hooks
  hooks            Activate git hooks only (no package install)
  all              Full pipeline: fetch → build → initramfs → test → report  [default]
  fetch            Fetch: auto-dispatches by preset — mainline -rc tag / stable vX.Y.* tag / stable-rc branch tip / errors on linux-next (use fetch-next)
  fetch-stable     Explicit stable tag fetch  (requires STABLE_RELEASE=; useful outside preset-managed clones)
  fetch-stable-rc  Explicit stable-rc branch fetch  (requires STABLE_RC_BRANCH=; useful outside preset-managed clones)
  fetch-next       linux-next branch fetch  (requires LINUX_NEXT=1; set automatically by presets/kernel-test-next.mk)
  smoke            Quick sanity: kunitconfig + tinyconfig, no fetch (preset auto-selected by directory name)
  full             Broader coverage: bootable configs (kunitconfig tinyconfig defconfig randdefconfig rand500config), no fetch
  local            Daily-driver build: localconfig x86_64 only, no fetch, no build timeout
  checkout         Fetch and checkout a specific tag or commit  (requires TAG=)
  info             Show current tag/commit checked out in KERNEL_TREE
  build            Build kernels for all CONFIGS × ARCHS
  initramfs        Assemble Toybox cpio initramfs for each arch
  test             Boot each (config, arch) in QEMU/KVM and run tests
  report           Generate HTML/text report; exits 1 when OVERALL=FAIL (any build/boot/test/mismatch failure)
  diff             Compare two report dirs for regressions/fixes; auto-detects latest two if OLD=/NEW= omitted
  baseline         Pin the latest report dir as the regression baseline; auto-diff will compare against it
  install          Install built kernel to /boot; olddefconfig + SHA256 refresh + dkms autoinstall + mkinitcpio + GRUB; warns if kernel untested (needs sudo, x86_64 only)
  dmesg            Capture host kernel dmesg, analyse errors/hardware, diff vs previous (writes dmesg/)
  config-archive   Scan all reports/ and populate configs/archive_passed/ + configs/archive_failed/
  replay           Re-test an archived config on the current kernel  (requires CONFIG_FILE=)
  bisect           Binary-search a failing config to find the responsible option(s)  (requires CONFIG_FILE=; opt: DRY_RUN=1 PINNED_OPTS=CONFIG_X,CONFIG_Y)
  kconfig-check    Static analysis: find missing 'select' in a subsystem Kconfig  (requires SUBSYSTEM=; opt: DRIVER= ARCHS= VERIFY=1 PASS2=1 SKIP_CFGS=CONFIG_X GATE_CFGS=CONFIG_X)
  kconfig-build    Exhaustive build+boot sweep for all options in a subsystem Kconfig  (requires SUBSYSTEM=; opt: DRIVER= ARCHS= DRY_RUN=1 GATE_CFGS=)
  clean            Remove build/ and cache/
  distclean        Remove build/, cache/, and reports/
  help             Show this message

Config profiles (CONFIGS=):
  defconfig        Boot+test  Architecture default — broad baseline coverage
  tinyconfig       Boot+test  Minimal kernel — tests lower bound of functionality
  allnoconfig      Boot+test  Everything disabled — absolute minimum boot path
  kunitconfig      Boot+test  defconfig + KUnit framework; KTAP results shown as kunit:N/N
  kunitrandconfig  Build only defconfig + all available KUnit test modules (random set per run); requires rebuild each run
  rand500config    Boot+test  tinyconfig + 500 random =y options (constrained: no sanitizers, torture tests, non-gzip compressors)
  randdefconfig    Boot+test  defconfig with 300 randomly disabled options; heavy subsystems forced off; KERNEL_GZIP pinned
  localconfig      Boot+test  /proc/config.gz base (running kernel); daily-driver; not in default CONFIGS
  allmodconfig     Build only All options as modules — catches build-time regressions
  randconfig       Build only Fully random config — catches compile-time regressions; constrained to exclude non-gzip compressors (BUILD_TIMEOUT capped)
  randkconfigconfig-<OPT>  Boot+test  Generated per-option by kconfig-build sweep; not in default CONFIGS; one per subsystem config entry

Variables (current values):
  KERNEL_TREE         = $(KERNEL_TREE)
  STABLE_KERNEL_TREE  = $(STABLE_KERNEL_TREE)  (used when STABLE_RELEASE is set)
  STABLE_RELEASE      = $(if $(STABLE_RELEASE),$(STABLE_RELEASE),(not set — mainline rc mode))
  STABLE_RC_BRANCH    = $(if $(STABLE_RC_BRANCH),$(STABLE_RC_BRANCH),(not set — used by: make fetch-stable-rc))
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
  LINUX_NEXT          = $(LINUX_NEXT)  (set to 1 by presets/kernel-test-next.mk; redirects fetch to make fetch-next)
  TOYBOX_VERSION      = $(TOYBOX_VERSION)  (Toybox release pinned in cache/toybox-{x86_64,i686,aarch64})
  DMESG_LABEL         = $(DMESG_LABEL)  (label for make dmesg: mainline/stable/longterm/linux-next)
  LABEL               = $(if $(LABEL),$(LABEL),(auto: STABLE_RELEASE→stable, linux-next tree→linux-next, vX.Y.Z→stable, else mainline))  (report dir prefix; set LABEL=longterm to override)
  CONFIG_FILE         = $(if $(CONFIG_FILE),$(CONFIG_FILE),(not set — used by: make replay/bisect CONFIG_FILE=<archive-path>))
  SEED_CONFIG         = $(if $(SEED_CONFIG),$(SEED_CONFIG),(not set — set automatically by make replay; seeds build.sh config step from archived .config))
  SUBSYSTEM           = $(if $(SUBSYSTEM),$(SUBSYSTEM),(not set — required by: make kconfig-check/kconfig-build SUBSYSTEM=<name>))
  DRIVER              = $(if $(DRIVER),$(DRIVER),(not set — restrict kconfig-check/kconfig-build to one driver: DRIVER=pinctrl-bm1880))
  VERIFY              = $(VERIFY)  (set to 1 to confirm kconfig-check candidates with an object build; arch from ARCHS)
  DRY_RUN             = $(DRY_RUN)  (set to 1 to print kconfig-build option list without building)
  PASS2               = $(PASS2)  (set to 1 to enable IS_ENABLED() pass in kconfig-check; high false-positive rate)
  SKIP_CFGS           = $(if $(SKIP_CFGS),$(SKIP_CFGS),(not set — skip symbols as candidates: SKIP_CFGS=CONFIG_DEBUG_FS,CONFIG_PM))
  GATE_CFGS           = $(if $(GATE_CFGS),$(GATE_CFGS),(not set — comma-separated extra symbols to enable for drivers inside nested if blocks))

Note: always use 'make all NO_FETCH=1 ...' rather than chaining 'build test report'
  individually — chaining stops at the first failure, so tests and the report
  are skipped when any build fails. 'make all' continues through all stages and
  always writes a report; the test loop automatically skips configs that did not build.

Note: run 'make clean' when switching between kernel trees (e.g. mainline → stable
  or stable → mainline). Build directories contain generated headers tied to the
  source tree they were built from; reusing them across trees causes subtle mismatches.

  'make fetch' auto-dispatches based on the preset loaded for this clone:
    mainline   (kernel-test)            → fetches latest v*-rc* tag
    stable     (kernel-test-stable)     → fetches latest vX.Y.* tag   (preset: STABLE_RELEASE=7.1)
    stable-rc  (kernel-test-stable-rc)  → fetches linux-X.Y.y branch  (preset: STABLE_RC_BRANCH=linux-7.1.y)
    linux-next (kernel-test-next)       → error; use make fetch-next   (preset: LINUX_NEXT=1; KERNEL_TREE=~/git/linux-next)

── Testing kernel releases ─────────────────────────────────────────────────────
  (identical workflow in all four clones — preset handles the differences)

  make fetch                                   # fetch the right thing for this clone
  make smoke                                   # quick sanity: kunitconfig + tinyconfig, all archs
  make full                                    # broader: 5 bootable configs, all archs
  make all NO_FETCH=1                          # full pipeline: all 9 configs + archs

── Daily-driver install ────────────────────────────────────────────────────────

  make local                                   # build localconfig x86_64 (no timeout)
  make install CONFIGS=localconfig ARCHS=x86_64  # install to /boot + mkinitcpio + GRUB (needs sudo)

  # Stable: preset sets GCC=gcc-15 automatically (stable kernels predate GCC 16).
  # Stable-rc: version (e.g. v7.1.4-rc2) is read from kernel Makefile; no git tag needed.
  # Pin a specific stable release instead of fetching latest:
  make checkout TAG=v7.1.3 STABLE_RELEASE=7.1
  make all NO_FETCH=1

── More ────────────────────────────────────────────────────────────────────────

  make info                                    # show HEAD commit, tag, kernel Makefile version

  # Fast iteration on test scripts — skip rebuild, repack initramfs and re-run tests
  make all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig

  # Single config + arch (quick check; report always written even on failure)
  make all NO_FETCH=1 CONFIGS=defconfig ARCHS=x86_64

  # Regression diff — auto-detects two most recent same-label runs
  make diff
  make diff OLD=reports/mainline-7.2-...-v7.2-rc1 NEW=reports/mainline-7.2-...-v7.2-rc2

  # Pin current results as baseline; future 'make all' runs auto-diff against it
  make baseline

  # Rename old-format report dirs to new label-prefixed format
  bash scripts/migrate-reports.sh          # dry-run — shows what would change
  bash scripts/migrate-reports.sh --apply  # rename dirs + update baseline symlink

  # Re-test an archived config on the current kernel
  make replay CONFIG_FILE=configs/archive_passed/kconfig-tinyconfig-x86_64-v7.2-rc2-<sha256>.config
  make replay CONFIG_FILE=configs/archive_failed/kconfig-randconfig-x86_64-v7.2-rc2-<sha256>-BUILD_FAIL.config

── Kconfig tools ───────────────────────────────────────────────────────────────

  # Static analysis: find missing 'select' in a subsystem (object-build confirm)
  make kconfig-check SUBSYSTEM=pinctrl DRIVER=pinctrl-bm1880 ARCHS=arm64 VERIFY=1

  # Exhaustive build+boot sweep — dry run first, then single driver, then full
  make kconfig-build SUBSYSTEM=pinctrl DRY_RUN=1
  make kconfig-build SUBSYSTEM=pinctrl DRIVER=pinctrl-bm1880 KERNEL_TREE=~/git/linux-dev
  make kconfig-build SUBSYSTEM=pinctrl ARCHS=arm64
endef
export HELP_TEXT

help:
	@echo "$$HELP_TEXT"
