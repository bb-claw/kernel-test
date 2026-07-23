#!/bin/sh
# VFS path resolution: symlinks, hard links, named pipes (FIFOs).
# tmpfs is always mounted at /tmp (forced by bootability fragment).
# FIFO write+read uses exec 3<> (O_RDWR) — avoids blocking open and any fork.

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
if grep -q "^line2$" "$HARD" 2>/dev/null; then
    ok "hard link: write to original visible through alias"
else
    fail "hard link: write not visible through alias"
fi

# ── FIFO (named pipe) ─────────────────────────────────────────────────────────
# Open with exec 3<> (O_RDWR): avoids blocking open (no separate reader/writer
# process needed) and avoids fork (safe on arm64 QEMU TCG).

FIFO="$WORK/testfifo"
mkfifo "$FIFO" 2>/dev/null || { fail "FIFO: mkfifo failed"; }

if [ -p "$FIFO" ]; then
    ok "FIFO: mkfifo created named pipe"
else
    fail "FIFO: named pipe not present after mkfifo"
fi

if exec 3<>"$FIFO" 2>/dev/null; then
    printf 'ping\n' >&3
    read result <&3 2>/dev/null
    exec 3>&-
    if [ "$result" = "ping" ]; then
        ok "FIFO: write + read round-trip"
    else
        fail "FIFO: round-trip failed (got '$result')"
    fi
else
    skip "FIFO: exec 3<> not supported"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

rm -rf "$WORK" 2>/dev/null || true

[ $fails -eq 0 ] || exit 1
