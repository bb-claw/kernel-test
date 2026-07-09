#!/bin/bash
# Aggregate build and VM results into reports/<date>_<version>/summary.{txt,html}.
# Reads status files written by build.sh and vm.sh.
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_env BUILD_DIR CONFIGS ARCHS BUILD_ONLY_CONFIGS REPORT_DIR RUN_STAMP

# ── Resolve kernel version ────────────────────────────────────────────────────

VERSION_FILE="$BUILD_DIR/.kernel-version"
KERNEL_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")

DATE=$(date -u +%Y-%m-%d)
RUN_DIR="$REPORT_DIR/${DATE}_${KERNEL_VERSION}"
mkdir -p "$RUN_DIR"

# ── Collect per-(config,arch) data ────────────────────────────────────────────

# read_status FILE KEY  — print value for KEY= line, or '?' if missing
read_status() {
    local file="$1" key="$2"
    grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || printf '?'
}

# Build a result table: rows are "config arch build boot tests_pass tests_total fail_reason"
ROWS=()
OVERALL=PASS

for config in $CONFIGS; do
    for arch in $ARCHS; do
        out="$BUILD_DIR/$config-$arch"

        build_status=$(read_status "$out/build.status" '' 2>/dev/null \
            || cat "$out/build.status" 2>/dev/null || echo '?')
        # build.status contains just PASS or FAIL (no KEY=)
        [[ -f "$out/build.status" ]] && build_status=$(cat "$out/build.status") || build_status='?'

        if is_build_only "$config"; then
            boot='build-only'
            tests_pass='-'
            tests_total='-'
            fail_reason=''
        elif [[ -f "$out/vm.status" ]]; then
            boot=$(read_status       "$out/vm.status" BOOT)
            tests_pass=$(read_status "$out/vm.status" TESTS_PASS)
            tests_total=$(read_status "$out/vm.status" TESTS_TOTAL)
            fail_reason=$(read_status "$out/vm.status" FAIL_REASON)
            [[ $fail_reason == '?' ]] && fail_reason=''
        else
            boot='?'; tests_pass='?'; tests_total='?'; fail_reason=''
        fi

        [[ $build_status == PASS ]] || OVERALL=FAIL
        [[ $boot == PASS || $boot == build-only || $boot == '?' ]] || OVERALL=FAIL

        # Copy dmesg
        [[ -f "$out/dmesg.txt" ]] && \
            cp "$out/dmesg.txt" "$RUN_DIR/dmesg-${config}-${arch}.txt"
        # Copy build log for build-only configs
        is_build_only "$config" && [[ -f "$out/build.log" ]] && \
            cp "$out/build.log" "$RUN_DIR/build-${config}-${arch}.log"

        ROWS+=("$config|$arch|$build_status|$boot|$tests_pass|$tests_total|$fail_reason")
    done
done

# ── Host info ─────────────────────────────────────────────────────────────────

HOST_ARCH=$(uname -m)
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
    | cut -d: -f2 | xargs || echo 'unknown')
RAM=$(awk '/MemTotal/ {printf "%.0f MiB", $2/1024}' /proc/meminfo 2>/dev/null \
    || echo 'unknown')

# ── summary.txt ───────────────────────────────────────────────────────────────

TXT="$RUN_DIR/summary.txt"
{
    printf 'Linux %s boot test report\n' "$KERNEL_VERSION"
    printf 'Host:   %s  |  %s  |  %s\n' "$HOST_ARCH" "$CPU_MODEL" "$RAM"
    printf 'Date:   %s\n' "$RUN_STAMP"
    printf 'Result: %s\n\n' "$OVERALL"

    printf '%-16s %-8s %-8s %-12s %-8s %s\n' \
        Config Arch Build Boot Tests Notes
    printf '%-16s %-8s %-8s %-12s %-8s %s\n' \
        ------ ---- ----- ---- ----- -----

    for row in "${ROWS[@]}"; do
        IFS='|' read -r cfg arc bld bt tp tt fr <<< "$row"
        if [[ $tp == '-' ]]; then
            tests_col='—'
        else
            tests_col="${tp}/${tt}"
        fi
        printf '%-16s %-8s %-8s %-12s %-8s %s\n' \
            "$cfg" "$arc" "$bld" "$bt" "$tests_col" "$fr"
    done

    printf '\nFull dmesg logs: %s/\n' "$RUN_DIR"
} > "$TXT"

# ── summary.html ──────────────────────────────────────────────────────────────

HTML="$RUN_DIR/summary.html"
{
    cat << HTMLHEAD
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Linux $KERNEL_VERSION — kernel-test report</title>
<style>
  body  { font-family: monospace; margin: 2em; color: #222; }
  h1    { font-size: 1.2em; }
  p     { margin: .3em 0; }
  table { border-collapse: collapse; margin-top: 1em; }
  th, td{ border: 1px solid #bbb; padding: .35em .75em; text-align: left; }
  th    { background: #f0f0f0; }
  .pass { background: #d4edda; color: #155724; font-weight: bold; }
  .fail { background: #f8d7da; color: #721c24; font-weight: bold; }
  .skip { background: #fff3cd; color: #856404; }
  .unk  { color: #888; }
</style>
</head>
<body>
<h1>Linux $KERNEL_VERSION — boot test report</h1>
<p>Host: $HOST_ARCH | $CPU_MODEL | $RAM</p>
<p>Date: $RUN_STAMP</p>
<p>Overall: <strong>$OVERALL</strong></p>
<table>
<tr><th>Config</th><th>Arch</th><th>Build</th><th>Boot</th><th>Tests</th><th>Notes</th></tr>
HTMLHEAD

    for row in "${ROWS[@]}"; do
        IFS='|' read -r cfg arc bld bt tp tt fr <<< "$row"

        # CSS class helpers
        bld_cls=$( [[ $bld == PASS ]] && echo pass || { [[ $bld == FAIL ]] && echo fail || echo unk; } )
        bt_cls=$(  [[ $bt  == PASS ]] && echo pass || { [[ $bt  == FAIL ]] && echo fail || { [[ $bt == build-only ]] && echo skip || echo unk; }; } )

        if [[ $tp == '-' ]]; then
            tests_cell='<td>—</td>'
        else
            tests_cell="<td>${tp}/${tt}</td>"
        fi

        printf '<tr><td>%s</td><td>%s</td><td class="%s">%s</td><td class="%s">%s</td>%s<td>%s</td></tr>\n' \
            "$cfg" "$arc" "$bld_cls" "$bld" "$bt_cls" "$bt" "$tests_cell" "$fr"
    done

    cat << HTMLFOOT
</table>
</body>
</html>
HTMLFOOT
} > "$HTML"

# ── Done ──────────────────────────────────────────────────────────────────────

info "Report written: $RUN_DIR/"
info "  summary.txt  — $TXT"
info "  summary.html — $HTML"
printf '\nOverall result: %s\n' "$OVERALL"
cat "$TXT"
