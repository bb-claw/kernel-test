#!/bin/sh
# VFS path resolution: symlinks, hard links, named pipes (FIFOs).
# tmpfs is always mounted at /tmp (forced by bootability fragment).
# FIFO subtest skipped on arm64: background writer forks the shell process;
# on arm64 QEMU TCG the COW fault on the full parent RSS immediately OOMs.

fails=0
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf 'skip: %s\n' "$*"; }

WORK=/tmp/vfs-links-$$
mkdir -p "$WORK" || { skip "vfs-links: cannot create work dir on tmpfs"; exit 0; }

# ── Symlinks ──────────────────────────────────────────────────────────────────

TARGET="$WORK/target"
LINK="$WORK/link"

printf 'hello\n' > "$TARGET"
ln -s "$TARGET" "$LINK" 2>/dev/null || { fail "ln -s failed"; }

if [ -L "$LINK" ]; then
    ok "symlink created"
else
    fail "symlink not present after ln -s"
fi

resolved=$(readlink "$LINK" 2>/dev/null)
if [ "$resolved" = "$TARGET" ]; then
    ok "readlink returns target path"
else
    fail "readlink returned '$resolved', expected '$TARGET'"
fi

# Dangling symlink: -e must be false when target is absent
DANGLE="$WORK/dangle"
ln -s "$WORK/absent" "$DANGLE" 2>/dev/null || true
if [ ! -e "$DANGLE" ]; then
    ok "dangling symlink: -e is false"
else
    fail "dangling symlink: -e is unexpectedly true"
fi

# ── Hard links ────────────────────────────────────────────────────────────────

ORIG="$WORK/orig"
HARD="$WORK/hardlink"

printf 'line1\n' > "$ORIG"
ln "$ORIG" "$HARD" 2>/dev/null || { fail "ln (hard link) failed"; }

if [ -f "$HARD" ]; then
    ok "hard link created"
else
    fail "hard link file not present"
fi

content=$(cat "$HARD" 2>/dev/null)
if [ "$content" = "line1" ]; then
    ok "hard link: initial content readable"
else
    fail "hard link: content mismatch (got '$content')"
fi

printf 'line2\n' >> "$ORIG"
content2=$(cat "$HARD" 2>/dev/null)
if [ "$content2" = "line1
line2" ]; then
    ok "hard link: write to original visible through alias"
else
    fail "hard link: write not visible through alias (got '$content2')"
fi

# ── FIFO (named pipe) — skip on arm64 ─────────────────────────────────────────

arch=$(uname -m 2>/dev/null)
if [ "$arch" = "aarch64" ]; then
    skip "FIFO: background fork OOMs on arm64 QEMU TCG"
else
    FIFO="$WORK/testfifo"
    mkfifo "$FIFO" 2>/dev/null || { fail "mkfifo failed"; }

    if [ -p "$FIFO" ]; then
        ok "FIFO: mkfifo created named pipe"
    else
        fail "FIFO: named pipe not present after mkfifo"
    fi

    printf 'ping\n' > "$FIFO" &
    writer_pid=$!
    result=$(cat "$FIFO" 2>/dev/null)
    wait $writer_pid 2>/dev/null || true

    if [ "$result" = "ping" ]; then
        ok "FIFO: write + read round-trip"
    else
        fail "FIFO: got '$result', expected 'ping'"
    fi
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

rm -rf "$WORK" 2>/dev/null || true

[ $fails -eq 0 ] || exit 1
