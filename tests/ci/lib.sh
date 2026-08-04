#!/bin/bash
# Shared helpers for tests/ci/ harness self-tests.
# Source this file at the top of each test script.
set -euo pipefail

_PASS=0; _FAIL=0; _TEST_NAME='(unknown)'

# Track temp dirs in a file so subshell writes are visible to teardown.
_TMPDIR_TRACK=$(mktemp)
teardown() { while IFS= read -r d; do rm -rf "$d"; done < "$_TMPDIR_TRACK"; rm -f "$_TMPDIR_TRACK"; }
trap teardown EXIT

# Create a temp dir and register it for cleanup. Sets _LAST_TMPDIR.
# Do NOT call via $() — use _LAST_TMPDIR after calling.
tmpdir() {
    _LAST_TMPDIR=$(mktemp -d)
    echo "$_LAST_TMPDIR" >> "$_TMPDIR_TRACK"
}
_LAST_TMPDIR=''

# ── Assertions ────────────────────────────────────────────────────────────────

pass() { (( _PASS++ )) || true; printf '  ok   %s\n' "${1:-}"; }
fail() { (( _FAIL++ )) || true; printf '  FAIL %s\n' "${1:-}"; }

assert_eq() {
    local actual="$1" expected="$2" msg="${3:-eq}"
    if [[ "$actual" == "$expected" ]]; then pass "$msg"
    else fail "$msg: got $(printf '%q' "$actual"), want $(printf '%q' "$expected")"; fi
}

assert_ne() {
    local actual="$1" unexpected="$2" msg="${3:-ne}"
    if [[ "$actual" != "$unexpected" ]]; then pass "$msg"
    else fail "$msg: value should not be $(printf '%q' "$actual")"; fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-contains}"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$msg"
    else fail "$msg: $(printf '%q' "$needle") not found in output"; fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-not-contains}"
    if [[ "$haystack" != *"$needle"* ]]; then pass "$msg"
    else fail "$msg: $(printf '%q' "$needle") unexpectedly found in output"; fi
}

assert_file_exists() {
    local path="$1" msg="${2:-file-exists: $1}"
    if [[ -f "$path" ]]; then pass "$msg"
    else fail "$msg"; fi
}

assert_exit0() {
    local msg="${1:-exit0}"; shift
    if "$@" >/dev/null 2>&1; then pass "$msg"
    else fail "$msg: exited non-zero"; fi
}

assert_exit1() {
    local msg="${1:-exit1}"; shift
    if ! "$@" >/dev/null 2>&1; then pass "$msg"
    else fail "$msg: unexpectedly exited 0"; fi
}

# ── Setup helpers ─────────────────────────────────────────────────────────────
# These set globals (DATA_REPO, KERNEL_TREE) and export them.
# Call directly — never via $() — so exports reach the parent shell.

# Create a minimal fake DATA_REPO git repo.
# Sets and exports DATA_REPO and REPORT_DIR.
setup_data_repo() {
    tmpdir
    local dr="$_LAST_TMPDIR"
    git init -q --initial-branch=main "$dr"
    git -C "$dr" config user.email "test@example.com"
    git -C "$dr" config user.name  "CI Test"
    mkdir -p "$dr/reports" "$dr/configs/archive_passed" "$dr/configs/archive_failed" \
              "$dr/consolidation" "$dr/dmesg"
    touch "$dr/.gitignore"
    git -C "$dr" add .gitignore
    git -C "$dr" commit -q -m "initial"
    DATA_REPO="$dr"
    REPORT_DIR="$dr/reports"
    export DATA_REPO REPORT_DIR
}

# Create a minimal fake KERNEL_TREE with a kernel Makefile.
# Sets and exports KERNEL_TREE.
# Args: [version=7.2] [extraversion=-rc99]
setup_kernel_tree() {
    local ver="${1:-7.2}" rc="${2:--rc99}"
    local major="${ver%%.*}" minor="${ver##*.}"
    tmpdir
    local kt="$_LAST_TMPDIR"
    {
        printf 'VERSION = %s\n' "$major"
        printf 'PATCHLEVEL = %s\n' "$minor"
        printf 'SUBLEVEL = 0\n'
        printf 'EXTRAVERSION = %s\n' "$rc"
        printf 'NAME = Test\n'
    } > "$kt/Makefile"
    git init -q "$kt"
    git -C "$kt" config user.email "test@example.com"
    git -C "$kt" config user.name  "CI Test"
    git -C "$kt" add Makefile
    git -C "$kt" commit -q -m "initial"
    KERNEL_TREE="$kt"
    export KERNEL_TREE
}

# Install a git stub that no-ops pull/push operations.
# Call directly — never via $() — so PATH export reaches the parent shell.
setup_git_stub() {
    tmpdir
    local bindir="$_LAST_TMPDIR/bin"
    mkdir "$bindir"
    local real_git
    real_git=$(command -v git)
    cat > "$bindir/git" <<STUB
#!/bin/bash
for arg; do
    case "\$arg" in pull|push) exit 0 ;; esac
done
exec "$real_git" "\$@"
STUB
    chmod +x "$bindir/git"
    PATH="$bindir:$PATH"
    export PATH
}

# ── Test runner ───────────────────────────────────────────────────────────────

begin_test() {
    _TEST_NAME="$1"
    printf '\n--- %s\n' "$_TEST_NAME"
}

# Call at the end of each test file.
finish() {
    printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$_PASS" "$_FAIL"
    [[ $_FAIL -eq 0 ]]
}
