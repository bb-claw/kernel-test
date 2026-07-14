#!/bin/bash
# Rename old-format report dirs to the new label-prefixed format.
# Old: YYYY-MM-DD_HH-MM-SS_vX.Y...
# New: label-MAJOR.MINOR-YYYY-MM-DD_HH-MM-SS-vX.Y...
# Dry-run by default; pass --apply to rename.
set -euo pipefail

REPORT_DIR="${REPORT_DIR:-reports}"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

[[ -d $REPORT_DIR ]] || { printf 'ERROR: %s not found\n' "$REPORT_DIR" >&2; exit 1; }

any=0
baseline_old=''
baseline_new=''

[[ -L "$REPORT_DIR/baseline" ]] && baseline_old=$(readlink "$REPORT_DIR/baseline") || true

while IFS= read -r d; do
    b=$(basename "$d")

    # Skip new-format dirs (already have label prefix)
    case "$b" in mainline-*|stable-*|longterm-*|linux-next-*)
        continue ;;
    esac

    # Parse old format: YYYY-MM-DD_HH-MM-SS_version
    if [[ ! $b =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})_(.+)$ ]]; then
        printf 'SKIP (unrecognized format): %s\n' "$b"
        continue
    fi
    datetime="${BASH_REMATCH[1]}"
    full_version="${BASH_REMATCH[2]}"

    # Guess label from version string
    if [[ $full_version =~ -rc[0-9]+$ ]]; then
        label=mainline
    elif [[ $full_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        label=stable
    else
        label=mainline
    fi

    # Extract major.minor
    if [[ $full_version =~ ^v([0-9]+\.[0-9]+) ]]; then
        version_short="${BASH_REMATCH[1]}"
    else
        version_short="${full_version#v}"
    fi

    new_b="${label}-${version_short}-${datetime}-${full_version}"
    any=1

    if [[ $APPLY -eq 0 ]]; then
        printf 'WOULD RENAME: %s\n  ->  %s\n' "$b" "$new_b"
    else
        mv "$d" "$REPORT_DIR/$new_b"
        printf 'RENAMED: %s -> %s\n' "$b" "$new_b"
        [[ "$b" == "$baseline_old" ]] && baseline_new="$new_b"
    fi
done < <(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d ! -name baseline | sort)

# Update baseline symlink when its target was renamed
if [[ $APPLY -eq 1 && -n $baseline_new ]]; then
    ln -sfn "$baseline_new" "$REPORT_DIR/baseline"
    printf 'UPDATED baseline -> %s\n' "$baseline_new"
fi

if [[ $any -eq 0 ]]; then
    printf 'No old-format dirs found in %s/\n' "$REPORT_DIR"
elif [[ $APPLY -eq 0 ]]; then
    printf '\nDry-run complete. Run with --apply to rename.\n'
fi
