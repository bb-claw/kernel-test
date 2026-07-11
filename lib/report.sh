#!/bin/bash
# Aggregate build and VM results into reports/<datetime>_<version>/summary.{txt,html}.
# Reads status files written by build.sh and vm.sh.
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_env BUILD_DIR CONFIGS ARCHS BUILD_ONLY_CONFIGS REPORT_DIR RUN_STAMP KERNEL_TREE

REPORT_GEN_EPOCH=$(date -u +%s)

# ── Resolve kernel version ────────────────────────────────────────────────────

VERSION_FILE="$BUILD_DIR/.kernel-version"
KERNEL_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || true)
if [[ -z $KERNEL_VERSION ]]; then
    KERNEL_VERSION=$(git -C "$KERNEL_TREE" describe --exact-match HEAD 2>/dev/null \
        || git -C "$KERNEL_TREE" rev-parse --short HEAD 2>/dev/null \
        || echo "unknown")
fi

# Directory name: YYYY-MM-DD_HH-MM-SS_<version>  (colons→dashes for fs safety)
RUN_DIR_STAMP=$(date -d "$RUN_STAMP" +%Y-%m-%d_%H-%M-%S 2>/dev/null \
    || echo "$RUN_STAMP" | sed 's/T/_/; s/://g; s/Z//')
RUN_DIR="$REPORT_DIR/${RUN_DIR_STAMP}_${KERNEL_VERSION}"
mkdir -p "$RUN_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

# read_status FILE KEY — print value for KEY= line, or '' if missing
read_status() {
    local file="$1" key="$2"
    grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# fmt_dur SECONDS — format as "5s", "1m23s", or "?" for unknown
fmt_dur() {
    local s=${1:-?}
    [[ $s == '?' || ! $s =~ ^[0-9]+$ ]] && { echo '?'; return; }
    (( s >= 60 )) && printf '%dm%02ds' $(( s / 60 )) $(( s % 60 )) \
                  || printf '%ds' "$s"
}

# fmt_time ISO8601 — extract HH:MM:SS, or "?"
fmt_time() {
    local ts=${1:-}
    [[ $ts =~ T([0-9]{2}:[0-9]{2}:[0-9]{2}) ]] && echo "${BASH_REMATCH[1]}" || echo '?'
}

# ── Collect per-(config,arch) data ────────────────────────────────────────────

ROWS=()
OVERALL=PASS

for config in $CONFIGS; do
    for arch in $ARCHS; do
        out="$BUILD_DIR/$config-$arch"

        # build.status is now KEY=VALUE; fall back gracefully for old plain-text files
        if [[ -f "$out/build.status" ]]; then
            build_status=$(read_status "$out/build.status" STATUS)
            [[ -z $build_status ]] && build_status=$(cat "$out/build.status")
            build_start=$(read_status  "$out/build.status" START_TIME)
            build_dur=$(read_status    "$out/build.status" DURATION)
        else
            build_status='?'; build_start=''; build_dur=''
        fi

        if is_build_only "$config"; then
            boot='build-only'
            tests_pass='-'; tests_total='-'
            fail_reason=''
            started=$(fmt_time "$build_start")
            duration=$(fmt_dur  "$build_dur")
        elif [[ -f "$out/vm.status" ]]; then
            boot=$(read_status        "$out/vm.status" BOOT)
            tests_pass=$(read_status  "$out/vm.status" TESTS_PASS)
            tests_total=$(read_status "$out/vm.status" TESTS_TOTAL)
            fail_reason=$(read_status "$out/vm.status" FAIL_REASON)
            vm_start=$(read_status    "$out/vm.status" START_TIME)
            vm_dur=$(read_status      "$out/vm.status" DURATION)
            started=$(fmt_time "$vm_start")
            duration=$(fmt_dur  "$vm_dur")
        else
            boot='?'; tests_pass='?'; tests_total='?'; fail_reason=''
            started='?'; duration='?'
        fi

        [[ $build_status == PASS ]] || OVERALL=FAIL
        [[ $boot == PASS || $boot == build-only || $boot == '?' ]] || OVERALL=FAIL

        # Copy dmesg and build logs into the report dir
        [[ -f "$out/dmesg.txt" ]] && \
            cp "$out/dmesg.txt" "$RUN_DIR/dmesg-${config}-${arch}.txt"
        is_build_only "$config" && [[ -f "$out/build.log" ]] && \
            cp "$out/build.log" "$RUN_DIR/build-${config}-${arch}.log"

        ROWS+=("$config|$arch|$build_status|$boot|$tests_pass|$tests_total|$started|$duration|$fail_reason")
    done
done

# ── Overall duration ──────────────────────────────────────────────────────────

RUN_START_EPOCH=$(date -d "$RUN_STAMP" +%s 2>/dev/null || echo "$REPORT_GEN_EPOCH")
OVERALL_DURATION=$(fmt_dur "$(( REPORT_GEN_EPOCH - RUN_START_EPOCH ))")

# ── Host info ─────────────────────────────────────────────────────────────────

HOST_ARCH=$(uname -m)
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
    | cut -d: -f2 | xargs || echo 'unknown')
RAM=$(awk '/MemTotal/ {printf "%.0f MiB", $2/1024}' /proc/meminfo 2>/dev/null \
    || echo 'unknown')

# ── Kernel source info ────────────────────────────────────────────────────────

REPO_URL=$(git -C "$KERNEL_TREE" remote get-url origin 2>/dev/null || echo 'unknown')
COMMIT_SHA=$(git -C "$KERNEL_TREE" rev-parse HEAD 2>/dev/null || echo 'unknown')

# ── summary.txt ───────────────────────────────────────────────────────────────

TXT="$RUN_DIR/summary.txt"
{
    printf 'Linux %s boot test report\n' "$KERNEL_VERSION"
    printf 'Repository: %s\n' "$REPO_URL"
    printf 'Commit:     %s\n' "$COMMIT_SHA"
    printf 'Host:       %s  |  %s  |  %s\n' "$HOST_ARCH" "$CPU_MODEL" "$RAM"
    printf 'Started:    %s\n' "$RUN_STAMP"
    printf 'Duration:   %s\n' "$OVERALL_DURATION"
    printf 'Result:     %s\n\n' "$OVERALL"

    printf '%-16s %-8s %-8s %-12s %-8s %-9s %-8s %s\n' \
        Config Arch Build Boot Tests Started Dur Notes
    printf '%-16s %-8s %-8s %-12s %-8s %-9s %-8s %s\n' \
        ------ ---- ----- ---- ----- ------- --- -----

    for row in "${ROWS[@]}"; do
        IFS='|' read -r cfg arc bld bt tp tt ts dur fr <<< "$row"
        [[ $tp == '-' ]] && tests_col='—' || tests_col="${tp}/${tt}"
        printf '%-16s %-8s %-8s %-12s %-8s %-9s %-8s %s\n' \
            "$cfg" "$arc" "$bld" "$bt" "$tests_col" "$ts" "$dur" "$fr"
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
<p>Repository: $REPO_URL</p>
<p>Commit: $COMMIT_SHA</p>
<p>Host: $HOST_ARCH | $CPU_MODEL | $RAM</p>
<p>Started: $RUN_STAMP</p>
<p>Duration: $OVERALL_DURATION</p>
<p>Overall: <strong>$OVERALL</strong></p>
<table>
<tr><th>Config</th><th>Arch</th><th>Build</th><th>Boot</th><th>Tests</th><th>Started</th><th>Dur</th><th>Notes</th></tr>
HTMLHEAD

    for row in "${ROWS[@]}"; do
        IFS='|' read -r cfg arc bld bt tp tt ts dur fr <<< "$row"

        bld_cls=$( [[ $bld == PASS ]] && echo pass || { [[ $bld == FAIL || $bld == TIMEOUT ]] && echo fail || echo unk; } )
        bt_cls=$(  [[ $bt  == PASS ]] && echo pass || { [[ $bt  == FAIL ]] && echo fail || { [[ $bt == build-only ]] && echo skip || echo unk; }; } )
        [[ $tp == '-' ]] && tests_cell='<td>—</td>' || tests_cell="<td>${tp}/${tt}</td>"

        printf '<tr><td>%s</td><td>%s</td><td class="%s">%s</td><td class="%s">%s</td>%s<td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$cfg" "$arc" "$bld_cls" "$bld" "$bt_cls" "$bt" "$tests_cell" "$ts" "$dur" "$fr"
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
printf '\nOverall result: %s  (duration: %s)\n' "$OVERALL" "$OVERALL_DURATION"
cat "$TXT"
