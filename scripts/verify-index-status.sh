#!/bin/sh
# verify-index-status.sh — SH-056 doc-staleness check.
#
# Catches: INDEX.md row status ≠ story frontmatter status.
#
# For every docs/stories/<ID>-<slug>.md file, extract its `status:` field
# from frontmatter and compare against the status column of the matching
# row in docs/stories/INDEX.md. Fail if any disagree, or if an INDEX row
# is missing for a shipped+ story.
#
# This specific drift class bit us 2026-11-23 (PR #55) when 6 shipped
# stories still showed `draft`/`in-progress` in the INDEX. verify-
# traceability doesn't catch it because it reads status from frontmatter
# only; this script closes the gap.
#
# Exit 0 clean; exit 1 on any mismatch.
#
# CAPs: dev-cycle.verify-index-status
# Story: docs/stories/SH-056-verify-index-status.md

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
stories="$root/docs/stories"
index="$stories/INDEX.md"

[ -f "$index" ] || { echo "verify-index-status: $index missing — nothing to check"; exit 0; }

fail=0
for f in "$stories"/*-*.md; do
    case "$(basename "$f")" in
        INDEX.md|_*.md) continue ;;  # skip index + templates
    esac
    [ -f "$f" ] || continue

    # Story ID — first two dash-separated tokens (e.g. SH-042, BC-150, FG-091).
    base=$(basename "$f" .md)
    id=$(printf '%s\n' "$base" | awk -F- '{print $1"-"$2}')

    # Frontmatter status — first `status:` line.
    fm_status=$(awk '/^status:/{print $2; exit}' "$f")
    if [ -z "$fm_status" ]; then
        echo "verify-index-status: $base: no status: in frontmatter"
        fail=1
        continue
    fi

    # INDEX row — `| <ID> | <status> | …`. Allow flexible whitespace.
    idx_row=$(grep -E "^\| *${id} *\|" "$index" || true)
    if [ -z "$idx_row" ]; then
        echo "verify-index-status: $id: missing INDEX.md row (frontmatter status=$fm_status)"
        fail=1
        continue
    fi

    # Status column — 3rd pipe-separated field, trimmed.
    idx_status=$(printf '%s\n' "$idx_row" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3}')
    if [ "$fm_status" != "$idx_status" ]; then
        echo "verify-index-status: $id: INDEX row status='$idx_status' but frontmatter says '$fm_status'"
        fail=1
    fi
done

if [ "$fail" = 0 ]; then
    echo "verify-index-status: ok (INDEX.md matches frontmatter for all stories)"
    exit 0
fi
echo "verify-index-status: mismatches found; sync docs/stories/INDEX.md with story frontmatter."
exit 1
