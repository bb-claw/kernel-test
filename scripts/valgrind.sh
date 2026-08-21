#!/bin/bash
# Run all C programs under Valgrind (glibc/static build, local only).
# Usage: make valgrind
# Output: terminal summary + per-run logs in valgrind/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROGRAMS_DIR="$REPO_ROOT/tests/programs"
SUPP="$PROGRAMS_DIR/valgrind.supp"
LOG_DIR="$REPO_ROOT/valgrind"
D=$(date +%Y-%m-%d_%H-%M-%S)

mkdir -p "$LOG_DIR"

PASS=0; FAIL=0; SKIP=0

# --error-exitcode=99: distinguishes Valgrind memory errors (99) from program
# errors (1), so ENOSYS/skip exits from perf-event/syscall-tests can be
# classified as skip rather than fail.
VG_FLAGS=(--error-exitcode=99 --leak-check=full --suppressions="$SUPP" --quiet)

die()  { printf 'error: %s\n' "$*" >&2; exit 2; }
info() { printf '[valgrind] %s\n' "$*"; }

command -v valgrind >/dev/null || die "valgrind not installed — run: make bootstrap"
command -v clang    >/dev/null || die "clang not installed — run: make bootstrap"
[[ -f "$SUPP" ]]               || die "suppressions not found: $SUPP"

# ── Clang static analyzer ─────────────────────────────────────────────────────

info "running Clang static analyzer..."
for prog in arena-test perf-event syscall-tests snapshot serial-capture; do
    printf '[valgrind] %-36s ' "scan/$prog"
    scan_log="$LOG_DIR/scan-${prog}-${D}.log"
    rc=0
    make -C "$PROGRAMS_DIR/$prog" scan > "$scan_log" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf 'PASS\n'; PASS=$((PASS+1))
    else
        printf 'FAIL  (see %s)\n' "${scan_log#"$REPO_ROOT/"}"; FAIL=$((FAIL+1))
    fi
done

# ── Build valgrind variants ────────────────────────────────────────────────────

info "building glibc/static valgrind variants..."
for prog in arena-test perf-event syscall-tests snapshot serial-capture; do
    make -C "$PROGRAMS_DIR/$prog" valgrind > /dev/null
done

# ── Run helpers ────────────────────────────────────────────────────────────────

record() {
    local rc="$1" log="$2" on_nonzero="$3"
    if [[ $rc -eq 0 ]]; then
        printf 'PASS\n'; PASS=$((PASS+1))
    elif [[ $rc -eq 99 ]]; then
        printf 'FAIL  (memory errors — see %s)\n' "${log#"$REPO_ROOT/"}"; FAIL=$((FAIL+1))
    elif [[ "$on_nonzero" == "skip" ]]; then
        printf 'skip  (exit %d)\n' "$rc"; SKIP=$((SKIP+1))
    else
        printf 'FAIL  (exit %d — see %s)\n' "$rc" "${log#"$REPO_ROOT/"}"; FAIL=$((FAIL+1))
    fi
}

# Run a program under Valgrind.
# on_nonzero: "fail" = non-zero exit is a failure; "skip" = treat as skip (syscall unavailable)
run_vg() {
    local name="$1" on_nonzero="$2"; shift 2
    local log="$LOG_DIR/${name//\//-}-${D}.log"
    printf '[valgrind] %-36s ' "$name"
    local rc=0
    valgrind "${VG_FLAGS[@]}" --log-file="$log" "$@" > /dev/null 2>&1 || rc=$?
    record "$rc" "$log" "$on_nonzero"
}

# Run serial-capture via a socat PTY pair.
# SIGTERM forwarded by Valgrind to serial-capture's handler; client exits 0 cleanly.
run_vg_serial() {
    local name="serial-capture"
    local bin="$PROGRAMS_DIR/serial-capture/bin/serial-capture-valgrind"
    local log="$LOG_DIR/${name}-${D}.log"
    local cap="$LOG_DIR/${name}-capture-${D}.txt"
    local pty="$LOG_DIR/vg-pty-${D}-$$.link"

    printf '[valgrind] %-36s ' "$name"

    if ! command -v socat > /dev/null 2>&1; then
        printf 'skip  (socat not installed)\n'; SKIP=$((SKIP+1)); return 0
    fi

    # PTY pair: socat feeds bytes to master; slave path exposed via symlink $pty
    socat PTY,rawer,link="$pty" EXEC:"printf 'HELLO\\n'; sleep 2" \
        > /dev/null 2>&1 &
    local socat_pid=$!
    # Poll for the symlink instead of a fixed sleep — reliable on loaded systems.
    local i=0
    until [[ -L "$pty" ]] || [[ $i -ge 20 ]]; do sleep 0.05; i=$((i+1)); done
    if [[ ! -L "$pty" ]]; then
        printf 'skip  (socat PTY not ready)\n'; SKIP=$((SKIP+1))
        kill "$socat_pid" 2>/dev/null || true; wait "$socat_pid" 2>/dev/null || true
        return 0
    fi

    local rc=0
    valgrind "${VG_FLAGS[@]}" --log-file="$log" \
        "$bin" "$pty" 115200 "$cap" > /dev/null 2>&1 &
    local vg_pid=$!

    sleep 0.4  # let serial-capture open the PTY and process at least one read()
    # SIGTERM to Valgrind is forwarded to the client process; serial-capture's
    # handler sets done=1 causing the read loop to exit; client exits 0.
    kill -TERM "$vg_pid" 2>/dev/null || true
    wait "$vg_pid" 2>/dev/null || rc=$?

    kill "$socat_pid" 2>/dev/null || true
    wait "$socat_pid" 2>/dev/null || true
    rm -f "$pty" "$cap"

    record "$rc" "$log" "fail"
}

# ── arena-test ────────────────────────────────────────────────────────────────
run_vg "arena-test" "fail" \
    "$PROGRAMS_DIR/arena-test/bin/x86_64/arena-test-valgrind"

# ── perf-event ────────────────────────────────────────────────────────────────
# Exits 1 if perf_event_open is unavailable (paranoid>2 or ENOSYS) → skip
run_vg "perf-event" "skip" \
    "$PROGRAMS_DIR/perf-event/bin/x86_64/perf-event-valgrind"

# ── syscall-tests ─────────────────────────────────────────────────────────────
# Subcommands exit 0 on pass/skip; exit 1 on test failure or missing kernel feature
SC="$PROGRAMS_DIR/syscall-tests/bin/x86_64/syscall-tests-valgrind"
for cmd in 32bit seccomp io_uring fds unix landlock bpf sysvipc-shm sysvipc-sem sysvipc-msg; do
    run_vg "syscall-tests/$cmd" "skip" "$SC" "$cmd"
done

# ── snapshot ──────────────────────────────────────────────────────────────────
run_vg "snapshot" "fail" \
    "$PROGRAMS_DIR/snapshot/bin/x86_64/snapshot-valgrind"

# ── serial-capture ────────────────────────────────────────────────────────────
run_vg_serial

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n'
printf '══════════════════════════════════════════════════════════════\n'
printf 'valgrind  PASS=%-3d  SKIP=%-3d  FAIL=%d\n' "$PASS" "$SKIP" "$FAIL"
printf 'logs: %s/\n' "${LOG_DIR#"$REPO_ROOT/"}"
printf '══════════════════════════════════════════════════════════════\n'

[[ $FAIL -eq 0 ]]
