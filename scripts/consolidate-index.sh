#!/bin/bash
# Merge per-source failure indexes into a unified consolidated view.
#
# Input:  consolidation/<source>/archive_failed/index.txt  (one per source)
# Output: consolidation/index.txt + consolidation/index.html
#
# Sources are any subdirectories of consolidation/ that contain
# archive_failed/index.txt.  Absent sources are silently skipped.
# consolidation/ is gitignored — all data stays local.
#
# Deduplicates by (source, SHA256): multiple runs of the same config
# in one source appear as one row.  The same SHA from two sources
# appears twice (cross-source reproducibility is the point).
#
# Run via: make consolidate-index
set -euo pipefail

DATA_REPO="${DATA_REPO:-}"
[[ -n $DATA_REPO && -d $DATA_REPO ]] || \
    { printf '[consolidate-index] ERROR: DATA_REPO directory does not exist: %s\nRun: make bootstrap\n' "${DATA_REPO:-<unset>}" >&2; exit 1; }
CONSOL_DIR="$DATA_REPO/consolidation"

info() { printf '[consolidate-index] %s\n' "$*"; }

html_attr_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

mkdir -p "$CONSOL_DIR"

# ── Collect rows from all per-source indexes ──────────────────────────────────
# Row format: version|config|arch|reason|sha|source
declare -a all_rows=()
declare -A seen=()     # "source|sha" → set  (dedup per source)
declare -A details=()  # sha → detail text (last detail line seen wins)
source_count=0

shopt -s nullglob
index_files=("$CONSOL_DIR"/*/archive_failed/index.txt)
shopt -u nullglob

for index_txt in "${index_files[@]}"; do
    [[ -f "$index_txt" ]] || continue
    source=$(basename "$(dirname "$(dirname "$index_txt")")")
    (( source_count++ )) || true
    cur_sha=""

    # tail -n +5 skips the 4-line header: title, blank, column names, separator
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        if [[ "$line" == "    -> "* ]]; then
            [[ -n "$cur_sha" ]] && details[$cur_sha]="${line#    -> }"
            continue
        fi

        # Data line: first four whitespace-delimited tokens are the key fields
        read -r config arch version reason _rest <<< "$line"
        [[ -z "$config" || "$config" == CONFIG ]] && continue
        sha=$(grep -oE '[0-9a-f]{64}' <<< "$line" | tail -1 || true)
        [[ -z "$sha" ]] && continue

        key="${source}|${sha}"
        if [[ -z "${seen[$key]+set}" ]]; then
            seen[$key]=1
            all_rows+=("${version}|${config}|${arch}|${reason}|${sha}|${source}")
        fi
        cur_sha="$sha"
    done < <(tail -n +5 "$index_txt")

    info "read: $source"
done

total=${#all_rows[@]}
date_str=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# ── Empty case ────────────────────────────────────────────────────────────────
if [[ $total -eq 0 ]]; then
    info "no sources found — writing empty index"
    printf 'Consolidated failure index — 0 entries — generated %s\n\nNo source data found.\nPopulate consolidation/<source>/archive_failed/index.txt first.\n' \
        "$date_str" > "$CONSOL_DIR/index.txt"
    {
        printf '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">'
        printf '<title>Consolidated failure index</title></head>\n'
        printf '<body style="font-family:monospace"><p>No source data found.</p>'
        printf '<p>Populate <code>consolidation/&lt;source&gt;/archive_failed/index.txt</code> first.</p>'
        printf '</body></html>\n'
    } > "$CONSOL_DIR/index.html"
    info "done (empty)"
    exit 0
fi

# ── Dynamic column widths ─────────────────────────────────────────────────────
w_src=6; w_c=6; w_a=4; w_v=7; w_r=14
for row in "${all_rows[@]}"; do
    IFS='|' read -r version config arch reason sha source <<< "$row"
    [[ ${#source}  -gt $w_src ]] && w_src=${#source}
    [[ ${#config}  -gt $w_c   ]] && w_c=${#config}
    [[ ${#arch}    -gt $w_a   ]] && w_a=${#arch}
    [[ ${#version} -gt $w_v   ]] && w_v=${#version}
    [[ ${#reason}  -gt $w_r   ]] && w_r=${#reason}
done

# ── Sort: version (version-sort), then config, arch, source ──────────────────
sorted=$(printf '%s\n' "${all_rows[@]}" | sort -t'|' -k1,1V -k2,2 -k3,3 -k6,6)

# ── index.txt ─────────────────────────────────────────────────────────────────
{
    printf 'Consolidated failure index — %d entries — generated %s\n\n' \
        "$total" "$date_str"
    printf "%-${w_src}s  %-${w_c}s  %-${w_a}s  %-${w_v}s  %-${w_r}s  %s\n" \
        SOURCE CONFIG ARCH VERSION "FAILURE REASON" SHA256
    seplen=$(( w_src + w_c + w_a + w_v + w_r + 64 + 10 ))
    printf '─%.0s' $(seq 1 "$seplen")
    printf '\n'
    while IFS='|' read -r version config arch reason sha source; do
        printf "%-${w_src}s  %-${w_c}s  %-${w_a}s  %-${w_v}s  %-${w_r}s  %s\n" \
            "$source" "$config" "$arch" "$version" "$reason" "$sha"
        if [[ -n "${details[$sha]+set}" ]]; then
            printf '    -> %s\n' "${details[$sha]}"
        fi
    done <<< "$sorted"
} > "$CONSOL_DIR/index.txt"

# ── index.html ────────────────────────────────────────────────────────────────
{
    printf '<!DOCTYPE html>\n<html lang="en">\n<head><meta charset="utf-8">\n'
    printf '<title>Consolidated failure index</title>\n'
    printf '<style>\n'
    printf 'body{font-family:monospace;margin:2em}\n'
    printf 'h1{font-size:1.1em}\n'
    printf 'table{border-collapse:collapse}\n'
    printf 'th,td{padding:4px 12px;text-align:left;border:1px solid #ccc}\n'
    printf 'th{background:#f0f0f0}\n'
    printf '.fail{color:#c00}\n'
    printf '.sha{font-size:0.85em;color:#666}\n'
    printf 'td[title]{cursor:help}\n'
    printf 'a{color:inherit}\n'
    printf '</style></head>\n<body>\n'
    printf '<h1>Consolidated failure index &mdash; %d entries &mdash; generated %s</h1>\n' \
        "$total" "$date_str"
    printf '<table>\n'
    printf '<tr><th>Source</th><th>Config</th><th>Arch</th><th>Version</th>'
    printf '<th>Failure reason</th><th>SHA256</th></tr>\n'
    while IFS='|' read -r version config arch reason sha source; do
        detail_attr=""
        if [[ -n "${details[$sha]+set}" ]]; then
            esc=$(html_attr_escape "${details[$sha]}")
            detail_attr=" title=\"${esc}\""
        fi
        printf '<tr><td><a href="%s/archive_failed/index.html">%s</a></td>' \
            "$source" "$source"
        printf '<td>%s</td><td>%s</td><td>%s</td>' "$config" "$arch" "$version"
        printf '<td class="fail"%s>%s</td><td class="sha">%s</td></tr>\n' \
            "$detail_attr" "$reason" "$sha"
    done <<< "$sorted"
    printf '</table>\n</body>\n</html>\n'
} > "$CONSOL_DIR/index.html"

info "wrote consolidation/index.{txt,html} — $total entries from $source_count source(s)"
