#!/bin/bash
# Branch verification gate: covers ≥50% of 35 functional decision paths.
# Fixed core (≥40%) always runs; random draw (≥10%) varies by SEED.
# Usage: scripts/dev-test.sh [SEED=N]
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
START_EPOCH=$(date +%s)
BUDGET=300  # soft 5-minute cap

# ── Seed ──────────────────────────────────────────────────────────────────────
if [[ -n "${SEED:-}" ]]; then
    SEED=$(( SEED + 0 ))
else
    SEED=$(( RANDOM * 32768 + RANDOM ))
fi

# ── Environment detection ──────────────────────────────────────────────────────
HAS_KVM=no;   [[ -r /dev/kvm ]]   && HAS_KVM=yes
HAS_LOCAL=no; [[ -r /proc/config.gz ]] && HAS_LOCAL=yes
HAS_BOARD=no
{ [[ -e /dev/ttyUSB0 ]] || [[ -L "${HW_RELAY:-/dev/vf2-relay}" ]]; } && HAS_BOARD=yes || true
HAS_RISCV_CC=no; command -v riscv64-linux-gnu-gcc &>/dev/null && HAS_RISCV_CC=yes || true
HAS_ARM64_CC=no; command -v aarch64-linux-gnu-gcc &>/dev/null && HAS_ARM64_CC=yes || true

# ── Output helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
BAR='──────────────────────────────────────────────────────────────────'

pass_count=0; fail_count=0; skip_count=0
covered_paths=()

result_pass() { local label=$1 elapsed=$2
    printf "  ${GREEN}PASS${RESET}  %-52s %ds\n" "$label" "$elapsed"
    pass_count=$(( pass_count + 1 ))
}
result_fail() { local label=$1 elapsed=$2
    printf "  ${RED}FAIL${RESET}  %-52s %ds\n" "$label" "$elapsed"
    fail_count=$(( fail_count + 1 ))
}
result_skip() { local label=$1 reason=$2
    printf "  ${YELLOW}skip${RESET}  %-52s (%s)\n" "$label" "$reason"
    skip_count=$(( skip_count + 1 ))
}

elapsed() { echo $(( $(date +%s) - START_EPOCH )); }

budget_ok() {
    local e; e=$(elapsed)
    if [[ $e -ge $BUDGET ]]; then
        printf "  ${YELLOW}warn${RESET}  time budget exceeded (%ds) — skipping remaining scenarios\n" "$e"
        return 1
    fi
    return 0
}

cover() { covered_paths+=("$@"); }

# ── Header ────────────────────────────────────────────────────────────────────
printf "${CYAN}[dev-test]${RESET} seed=%-10d  env: " "$SEED"
[[ $HAS_KVM = yes ]]      && printf "KVM=yes "      || printf "KVM=no "
[[ $HAS_LOCAL = yes ]]    && printf "local=yes "    || printf "local=no "
[[ $HAS_BOARD = yes ]]    && printf "board=yes "    || printf "board=no "
[[ $HAS_RISCV_CC = yes ]] && printf "riscv-cc=yes " || printf "riscv-cc=no "
[[ $HAS_ARM64_CC = yes ]] && printf "arm64-cc=yes"  || printf "arm64-cc=no"
printf "\n%s\n" "$BAR"

# ═══════════════════════════════════════════════════════════════════════════════
# FIXED CORE — always runs
# ═══════════════════════════════════════════════════════════════════════════════

# ── C1: make lint ─────────────────────────────────────────────────────────────
t0=$(date +%s)
if make -C "$REPO_ROOT" lint &>/tmp/dev-test-lint.log; then
    result_pass "lint" $(( $(date +%s) - t0 ))
else
    result_fail "lint" $(( $(date +%s) - t0 ))
    printf "       see /tmp/dev-test-lint.log\n"
fi

# ── C2: C programs build (4 arches × all programs) ───────────────────────────
budget_ok || { result_skip "C programs build" "budget"; true; } && {
t0=$(date +%s)
if make -C "$REPO_ROOT/tests/programs" all &>/tmp/dev-test-cprog.log; then
    result_pass "C programs build (4 arches × all programs)" $(( $(date +%s) - t0 ))
    cover C6 C7
else
    result_fail "C programs build" $(( $(date +%s) - t0 ))
    printf "       see /tmp/dev-test-cprog.log\n"
fi
}

# ── C3: key CI tests ──────────────────────────────────────────────────────────
budget_ok || { result_skip "ci-tests: vm-parser report snapshot diff" "budget"; true; } && {
t0=$(date +%s)
ci_label="ci-tests: vm-parser report snapshot diff"
if bash "$REPO_ROOT/tests/ci/test-vm-parser.sh" &>/tmp/dev-test-citest-parser.log \
    && bash "$REPO_ROOT/tests/ci/test-report.sh" &>/tmp/dev-test-citest-report.log \
    && bash "$REPO_ROOT/tests/ci/test-snapshot.sh" &>/tmp/dev-test-citest-snapshot.log \
    && bash "$REPO_ROOT/tests/ci/test-diff.sh" &>/tmp/dev-test-citest-diff.log; then
    result_pass "$ci_label" $(( $(date +%s) - t0 ))
    cover C1 C2 C3 C4 C5
else
    result_fail "$ci_label" $(( $(date +%s) - t0 ))
    for f in parser report snapshot diff; do
        log="/tmp/dev-test-citest-$f.log"
        [[ -s $log ]] && grep -q 'FAIL\|Error\|error' "$log" && printf "       %s: see %s\n" "$f" "$log" || true
    done
fi
}

# ── C4: tinyconfig/x86_64 VM smoke (NO_BUILD=1) ──────────────────────────────
budget_ok || { result_skip "VM smoke: tinyconfig/x86_64" "budget"; true; } && {
t0=$(date +%s)
if make -C "$REPO_ROOT" all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS=x86_64 \
        &>/tmp/dev-test-tiny-x86.log; then
    result_pass "VM smoke: tinyconfig/x86_64" $(( $(date +%s) - t0 ))
    cover A1 A2 A3 A6 A8 B1 B2
else
    result_fail "VM smoke: tinyconfig/x86_64" $(( $(date +%s) - t0 ))
    printf "       see /tmp/dev-test-tiny-x86.log\n"
fi
}

# ── C5: defconfig/x86_64 VM smoke (NO_BUILD=1) ───────────────────────────────
budget_ok || { result_skip "VM smoke: defconfig/x86_64" "budget"; true; } && {
t0=$(date +%s)
if make -C "$REPO_ROOT" all NO_FETCH=1 NO_BUILD=1 CONFIGS=defconfig ARCHS=x86_64 \
        &>/tmp/dev-test-def-x86.log; then
    result_pass "VM smoke: defconfig/x86_64" $(( $(date +%s) - t0 ))
    cover A1 A3 A6 B1
else
    result_fail "VM smoke: defconfig/x86_64" $(( $(date +%s) - t0 ))
    printf "       see /tmp/dev-test-def-x86.log\n"
fi
}

# ── C6: localconfig/x86_64 VM smoke (skip if /proc/config.gz absent) ─────────
if [[ $HAS_LOCAL = yes ]]; then
    budget_ok || { result_skip "VM smoke: localconfig/x86_64" "budget"; true; } && {
    t0=$(date +%s)
    if make -C "$REPO_ROOT" all NO_FETCH=1 NO_BUILD=1 CONFIGS=localconfig ARCHS=x86_64 \
            &>/tmp/dev-test-local-x86.log; then
        result_pass "VM smoke: localconfig/x86_64" $(( $(date +%s) - t0 ))
        cover B5
    else
        result_fail "VM smoke: localconfig/x86_64" $(( $(date +%s) - t0 ))
        printf "       see /tmp/dev-test-local-x86.log\n"
    fi
    }
else
    result_skip "VM smoke: localconfig/x86_64" "/proc/config.gz absent"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RANDOM POOL — weighted draw from remaining 21 paths
# ═══════════════════════════════════════════════════════════════════════════════
printf "%s\n" "$BAR" | sed 's/──/─/g'
cols=$(tput cols 2>/dev/null || echo 70)
printf "── ${CYAN}random${RESET} (seed=%d) %s\n" "$SEED" "$BAR" | cut -c1-"$cols" || true
printf "%s\n" "$BAR" | sed 's/──/─/g'

# Pool entries: "ID weight label command"
# Weight 1=<30s (CI fixtures/dry-run), 2=20-60s (VM combos), 3=60-120s (TCG)
# Entries separated such that we can shuffle and pick by weight budget.

# Build the pool array respecting environment constraints.
# Format: "IDs|weight|label|command"  — pipe separator avoids clash with ':' in labels.
pool=()

# Weight-2 VM config combos (random config variants on x86_64)
pool+=("A4_A5_A7|2|ci-test: test-vm-parser.sh (FAIL/TIMEOUT paths)|bash $REPO_ROOT/tests/ci/test-vm-parser.sh")
pool+=("B3|2|VM smoke: rand500config/x86_64 (NO_BUILD=1)|make -C $REPO_ROOT all NO_FETCH=1 NO_BUILD=1 CONFIGS=rand500config ARCHS=x86_64")
pool+=("B4|2|VM smoke: randdefconfig/x86_64 (NO_BUILD=1)|make -C $REPO_ROOT all NO_FETCH=1 NO_BUILD=1 CONFIGS=randdefconfig ARCHS=x86_64")
pool+=("B6|2|VM smoke: tinynsconfig/x86_64 (NO_BUILD=1)|make -C $REPO_ROOT all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinynsconfig ARCHS=x86_64")

# Weight-3 cross-arch TCG (only if cross-compiler available)
if [[ $HAS_ARM64_CC = yes ]]; then
    pool+=("D1|3|VM smoke: defconfig/arm64 (NO_BUILD=1)|make -C $REPO_ROOT all NO_FETCH=1 NO_BUILD=1 CONFIGS=defconfig ARCHS=arm64")
fi
if [[ $HAS_RISCV_CC = yes ]]; then
    pool+=("D2|3|VM smoke: defconfig/riscv (NO_BUILD=1)|make -C $REPO_ROOT all NO_FETCH=1 NO_BUILD=1 CONFIGS=defconfig ARCHS=riscv")
fi
pool+=("D3|3|VM smoke: tinyconfig/i386 (NO_BUILD=1)|make -C $REPO_ROOT all NO_FETCH=1 NO_BUILD=1 CONFIGS=tinyconfig ARCHS=i386")

# Weight-1 CI fixture tests (fast; always available regardless of kernel/QEMU)
pool+=("E1|1|ci-test: test-arch-scripts.sh|bash $REPO_ROOT/tests/ci/test-arch-scripts.sh")
pool+=("E2|1|ci-test: test-common.sh|bash $REPO_ROOT/tests/ci/test-common.sh")
pool+=("E3|1|ci-test: test-config-bisect.sh|bash $REPO_ROOT/tests/ci/test-config-bisect.sh")
pool+=("E4|1|ci-test: test-lint-context.sh|bash $REPO_ROOT/tests/ci/test-lint-context.sh")
pool+=("E5|1|ci-test: test-makefile-defaults.sh|bash $REPO_ROOT/tests/ci/test-makefile-defaults.sh")
pool+=("E6|1|ci-test: test-warnings.sh|bash $REPO_ROOT/tests/ci/test-warnings.sh")
pool+=("F1|1|ci-test: test-fetch.sh|bash $REPO_ROOT/tests/ci/test-fetch.sh")
pool+=("F2|1|ci-test: test-ns-configs.sh|bash $REPO_ROOT/tests/ci/test-ns-configs.sh")
pool+=("F3|1|ci-test: test-ns-scripts.sh|bash $REPO_ROOT/tests/ci/test-ns-scripts.sh")
pool+=("F4|1|ci-test: test-ns-build.sh|bash $REPO_ROOT/tests/ci/test-ns-build.sh")

# Hardware board paths — skip unless board present
if [[ $HAS_BOARD = yes ]]; then
    pool+=("D4|2|ci-test: test-board-serial.sh|bash $REPO_ROOT/tests/ci/test-board-serial.sh")
    pool+=("D5|2|ci-test: test-hw-bootstrap.sh|bash $REPO_ROOT/tests/ci/test-hw-bootstrap.sh")
    pool+=("D6|2|hw-bootstrap dry-run|make -C $REPO_ROOT hw-bootstrap DRY_RUN=1")
else
    result_skip "board paths D4 D5 D6" "HAS_BOARD=no"
fi

# Assign a uniform random key to each pool entry, then sort descending.
# LCG state is updated inline — NOT via a function called with $() — because
# $() creates a subshell and discards state changes, making every entry get
# the same key and breaking randomisation entirely.
lcg_state=$SEED
declare -a keyed=()
for entry in "${pool[@]}"; do
    lcg_state=$(( (1103515245 * lcg_state + 12345) & 0x7fffffff ))
    keyed+=("$lcg_state|$entry")
done

mapfile -t sorted < <(printf '%s\n' "${keyed[@]}" | sort -t'|' -k1 -rn)

# Target: draw until we've covered ≥9 additional paths or hit budget
TARGET_RANDOM=9
random_covered=0

for keyed_entry in "${sorted[@]}"; do
    entry="${keyed_entry#*|}"           # strip sort-key prefix
    ids=$(  printf '%s' "$entry" | cut -d'|' -f1)
    label=$(printf '%s' "$entry" | cut -d'|' -f3)
    cmd=$(  printf '%s' "$entry" | cut -d'|' -f4-)

    budget_ok || break

    t0=$(date +%s)
    log="/tmp/dev-test-rand-$(printf '%s' "$ids" | tr '/' '-').log"
    if eval "$cmd" &>"$log"; then
        result_pass "$label" $(( $(date +%s) - t0 ))
        IFS='_' read -ra id_list <<< "$ids"
        cover "${id_list[@]}"
        random_covered=$(( random_covered + ${#id_list[@]} ))
    else
        result_fail "$label" $(( $(date +%s) - t0 ))
        printf "       see %s\n" "$log"
    fi

    [[ $random_covered -ge $TARGET_RANDOM ]] && break
done

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
printf "%s\n" "$BAR"

# Deduplicate covered paths
mapfile -t unique_covered < <(printf '%s\n' "${covered_paths[@]}" | sort -u)
total_paths=35
covered_count=${#unique_covered[@]}
pct=$(( covered_count * 100 / total_paths ))
elapsed_total=$(elapsed)

if [[ $fail_count -eq 0 ]]; then
    printf "  ${GREEN}PASS${RESET}  dev-test complete  paths=%d/%d (%d%%)  time=%ds\n" \
        "$covered_count" "$total_paths" "$pct" "$elapsed_total"
    printf "        re-run: make dev-test SEED=%d\n" "$SEED"
    exit 0
else
    printf "  ${RED}FAIL${RESET}  dev-test FAILED  paths=%d/%d (%d%%)  time=%ds\n" \
        "$covered_count" "$total_paths" "$pct" "$elapsed_total"
    printf "        re-run: make dev-test SEED=%d\n" "$SEED"
    exit 1
fi
