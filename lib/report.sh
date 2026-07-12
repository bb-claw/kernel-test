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
CONFIG_ROWS=()
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
            config_sha256=$(read_status "$out/build.status" CONFIG_SHA256)
        else
            build_status='?'; build_start=''; build_dur=''; config_sha256=''
        fi

        if is_build_only "$config"; then
            boot='build-only'
            tests_pass='-'; tests_total='-'
            kunit_pass='0'; kunit_fail='0'; fail_reason=''
            started=$(fmt_time "$build_start")
            duration=$(fmt_dur  "$build_dur")
        elif [[ -f "$out/vm.status" ]]; then
            boot=$(read_status        "$out/vm.status" BOOT)
            tests_pass=$(read_status  "$out/vm.status" TESTS_PASS)
            tests_fail=$(read_status  "$out/vm.status" TESTS_FAIL)
            tests_total=$(read_status "$out/vm.status" TESTS_TOTAL)
            kunit_pass=$(read_status  "$out/vm.status" KUNIT_PASS)
            kunit_fail=$(read_status  "$out/vm.status" KUNIT_FAIL)
            fail_reason=$(read_status    "$out/vm.status" FAIL_REASON)
            failed_tests=$(read_status  "$out/vm.status" FAILED_TESTS)
            vm_start=$(read_status      "$out/vm.status" START_TIME)
            vm_dur=$(read_status      "$out/vm.status" DURATION)
            started=$(fmt_time "$vm_start")
            duration=$(fmt_dur  "$vm_dur")
        else
            boot='?'; tests_pass='?'; tests_fail='0'; tests_total='?'
            kunit_pass='0'; kunit_fail='0'; fail_reason=''; failed_tests=''
            started='?'; duration='?'
        fi

        [[ $build_status == PASS ]] || OVERALL=FAIL
        [[ $boot == PASS || $boot == build-only || $boot == '?' ]] || OVERALL=FAIL
        [[ ${tests_fail:-0} -eq 0 ]] || OVERALL=FAIL
        [[ ${kunit_fail:-0} -eq 0 ]] || OVERALL=FAIL

        # Copy artifacts into the report dir
        [[ -f "$out/dmesg.txt" ]] && \
            cp "$out/dmesg.txt" "$RUN_DIR/dmesg-${config}-${arch}.txt"
        [[ -f "$out/build.log" ]] && \
            cp "$out/build.log" "$RUN_DIR/build-${config}-${arch}.log"
        [[ -f "$out/qemu.log" ]] && \
            cp "$out/qemu.log"  "$RUN_DIR/qemu-${config}-${arch}.log"
        [[ -f "$out/.config" ]] && \
            cp "$out/.config" "$RUN_DIR/kconfig-${config}-${arch}.config"
        [[ -f "$out/rand-sampled.config" ]] && \
            cp "$out/rand-sampled.config" "$RUN_DIR/rand-sampled-${config}-${arch}.config"
        [[ -f "$out/randdef-disabled.config" ]] && \
            cp "$out/randdef-disabled.config" "$RUN_DIR/randdef-disabled-${config}-${arch}.config"
        [[ -f "$out/vm.status" ]] && \
            cp "$out/vm.status" "$RUN_DIR/vmstatus-${config}-${arch}.txt"

        # Verify stored config matches build-time fingerprint
        config_file="kconfig-${config}-${arch}.config"
        if [[ -n $config_sha256 && -f "$RUN_DIR/$config_file" ]]; then
            stored_sha=$(sha256sum "$RUN_DIR/$config_file" | awk '{print $1}')
            [[ $stored_sha == "$config_sha256" ]] && config_verify=OK || config_verify=MISMATCH
        else
            config_verify='?'
        fi
        [[ $config_verify != MISMATCH ]] || OVERALL=FAIL
        CONFIG_ROWS+=("$config|$arch|${config_sha256:-unknown}|$config_file|$config_verify")

        ROWS+=("$config|$arch|$build_status|$boot|$tests_pass|$tests_total|${kunit_pass:-0}|${kunit_fail:-0}|$started|$duration|$fail_reason|${failed_tests:-}")
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

# ── LKML identity (from harness repo git config) ──────────────────────────────

_git_name=$(git config user.name  2>/dev/null || echo '')
_git_email=$(git config user.email 2>/dev/null || echo '')
if [[ -n $_git_name && -n $_git_email ]]; then
    TESTED_BY="$_git_name <$_git_email>"
else
    TESTED_BY=''
fi
ARCH_LIST=$(echo "$ARCHS" | tr ' ' '/')

# ── summary.txt ───────────────────────────────────────────────────────────────

TXT="$RUN_DIR/summary.txt"
{
    # LKML-ready header — paste into email Subject: / body as-is
    printf 'Subject: [REPORT] Linux %s boot test: %s on %s\n' "$KERNEL_VERSION" "$OVERALL" "$ARCH_LIST"
    printf 'build and booted: %s\n' "$OVERALL"
    printf 'Repository:       %s\n' "$REPO_URL"
    printf 'Commit:           %s\n' "$COMMIT_SHA"
    printf 'Host:             %s  |  %s  |  %s\n' "$HOST_ARCH" "$CPU_MODEL" "$RAM"
    printf 'Tested ARCH:      %s\n' "$ARCHS"
    printf '\n'
    [[ -n $TESTED_BY ]] && printf 'Tested-by: %s\n' "$TESTED_BY"
    printf '\n---\n\n'

    printf 'Linux %s boot test report\n' "$KERNEL_VERSION"
    printf 'Repository: %s\n' "$REPO_URL"
    printf 'Commit:     %s\n' "$COMMIT_SHA"
    printf 'Host:       %s  |  %s  |  %s\n' "$HOST_ARCH" "$CPU_MODEL" "$RAM"
    printf 'Started:    %s\n' "$RUN_STAMP"
    printf 'Duration:   %s\n' "$OVERALL_DURATION"
    printf 'Result:     %s\n\n' "$OVERALL"

    printf '%-16s %-8s %-8s %-12s %-14s %-9s %-8s %s\n' \
        Config Arch Build Boot Tests Started Dur Notes
    printf '%-16s %-8s %-8s %-12s %-14s %-9s %-8s %s\n' \
        ------ ---- ----- ---- ----- ------- --- -----

    for row in "${ROWS[@]}"; do
        IFS='|' read -r cfg arc bld bt tp tt kp kf ts dur fr ftests <<< "$row"
        if [[ $tp == '-' ]]; then
            tests_col='—'
        else
            kunit_total=$(( ${kp:-0} + ${kf:-0} ))
            if [[ $kunit_total -gt 0 ]]; then
                tests_col="kunit:${kp}/${kunit_total}"
                [[ ${tt:-0} -gt 0 ]] && tests_col="${tests_col} sh:${tp}/${tt}"
            else
                tests_col="${tp}/${tt}"
            fi
        fi
        notes="${fr}"
        [[ -n $ftests ]] && notes="${notes:+$notes | }failed: ${ftests// /, }"
        printf '%-16s %-8s %-8s %-12s %-14s %-9s %-8s %s\n' \
            "$cfg" "$arc" "$bld" "$bt" "$tests_col" "$ts" "$dur" "$notes"
    done

    printf '\nConfig fingerprints (sha256):\n'
    printf '  %-16s %-8s %-64s %-10s %s\n' Config Arch SHA256 Verified File
    printf '  %-16s %-8s %-64s %-10s %s\n' ------ ---- ------ -------- ----
    for crow in "${CONFIG_ROWS[@]}"; do
        IFS='|' read -r cfg arc sha file ok <<< "$crow"
        printf '  %-16s %-8s %-64s %-10s %s\n' "$cfg" "$arc" "$sha" "$ok" "$file"
    done

    printf '\nReport dir: %s/\n' "$RUN_DIR"
} > "$TXT"

# ── summary.mail.txt ──────────────────────────────────────────────────────────────
# Email-ready preamble only — paste as the body of an LKML report mail.

MAIL="$RUN_DIR/summary.mail.txt"
{
    printf 'Subject: [REPORT] Linux %s boot test: %s on %s\n' "$KERNEL_VERSION" "$OVERALL" "$ARCH_LIST"
    printf 'build and booted: %s\n' "$OVERALL"
    printf 'Repository:       %s\n' "$REPO_URL"
    printf 'Commit:           %s\n' "$COMMIT_SHA"
    printf 'Host:             %s  |  %s  |  %s\n' "$HOST_ARCH" "$CPU_MODEL" "$RAM"
    printf 'Tested ARCH:      %s\n' "$ARCHS"
    printf '\n'
    [[ -n $TESTED_BY ]] && printf 'Tested-by: %s\n' "$TESTED_BY"
    printf '\n'
} > "$MAIL"

# ── summary.html ──────────────────────────────────────────────────────────────

HTML="$RUN_DIR/summary.html"
overall_cls=$( [[ $OVERALL == PASS ]] && echo pass || echo fail )
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
  td a  { color: #0066cc; text-decoration: underline; }
</style>
</head>
<body>
<h1>Linux $KERNEL_VERSION — boot test report</h1>
<p>Repository: $REPO_URL</p>
<p>Commit: $COMMIT_SHA</p>
<p>Host: $HOST_ARCH | $CPU_MODEL | $RAM</p>
<p>Started: $RUN_STAMP</p>
<p>Duration: $OVERALL_DURATION</p>
<p><span class="$overall_cls" style="padding:.25em .6em;border-radius:3px">Overall: <strong>$OVERALL</strong></span></p>
<p>Files: <a href="summary.txt">summary.txt</a> | <a href="summary.mail.txt">summary.mail.txt</a></p>
<table>
<tr><th>Config</th><th>Arch</th><th>Build</th><th>Boot</th><th>Tests</th><th>Started</th><th>Dur</th><th>Notes</th></tr>
HTMLHEAD

    for row in "${ROWS[@]}"; do
        IFS='|' read -r cfg arc bld bt tp tt kp kf ts dur fr ftests <<< "$row"

        # shellcheck disable=SC2015  # echo always succeeds; A && echo x || echo y is safe
        bld_cls=$( [[ $bld == PASS ]] && echo pass || { [[ $bld == FAIL || $bld == TIMEOUT ]] && echo fail || echo unk; } )
        # shellcheck disable=SC2015
        bt_cls=$(  [[ $bt  == PASS ]] && echo pass || { [[ $bt  == FAIL ]] && echo fail || { [[ $bt == build-only ]] && echo skip || echo unk; }; } )

        # Artifact links (relative paths — HTML lives in same dir)
        build_log="build-${cfg}-${arc}.log"
        dmesg_file="dmesg-${cfg}-${arc}.txt"
        qemu_log="qemu-${cfg}-${arc}.log"
        [[ -f "$RUN_DIR/$build_log" ]] \
            && bld_cell="<td class=\"${bld_cls}\"><a href=\"${build_log}\">${bld}</a></td>" \
            || bld_cell="<td class=\"${bld_cls}\">${bld}</td>"
        if [[ $bt == build-only ]]; then
            bt_cell="<td class=\"${bt_cls}\">${bt}</td>"
        elif [[ -f "$RUN_DIR/$dmesg_file" ]]; then
            bt_cell="<td class=\"${bt_cls}\"><a href=\"${dmesg_file}\">${bt}</a></td>"
        else
            bt_cell="<td class=\"${bt_cls}\">${bt}</td>"
        fi
        notes_content="${fr}"
        [[ -f "$RUN_DIR/$qemu_log" ]] && {
            [[ -n $notes_content ]] && notes_content="${notes_content} "
            notes_content="${notes_content}<a href=\"${qemu_log}\">[qemu]</a>"
        }
        if [[ -n $ftests ]]; then
            [[ -n $notes_content ]] && notes_content="${notes_content} "
            notes_content="${notes_content}<span class=\"fail\">failed: ${ftests// /, }</span>"
        fi

        if [[ $tp == '-' ]]; then
            tests_cell='<td>—</td>'
        else
            kunit_total=$(( ${kp:-0} + ${kf:-0} ))
            if [[ $kunit_total -gt 0 ]]; then
                tests_label="kunit:${kp}/${kunit_total}"
                [[ ${tt:-0} -gt 0 ]] && tests_label="${tests_label} sh:${tp}/${tt}"
            else
                tests_label="${tp}/${tt}"
            fi
            tests_cell="<td>${tests_label}</td>"
        fi

        printf '<tr><td>%s</td><td>%s</td>%s%s%s<td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$cfg" "$arc" "$bld_cell" "$bt_cell" "$tests_cell" "$ts" "$dur" "$notes_content"
    done

    printf '</table>\n<h2 style="font-size:1em;margin-top:1.5em">Config fingerprints (sha256)</h2>\n'
    printf '<table>\n<tr><th>Config</th><th>Arch</th><th>SHA256</th><th>Verified</th><th>File</th><th>Extras</th></tr>\n'
    for crow in "${CONFIG_ROWS[@]}"; do
        IFS='|' read -r cfg arc sha file ok <<< "$crow"
        # shellcheck disable=SC2015  # echo always succeeds; safe
        ok_cls=$( [[ $ok == OK ]] && echo pass || { [[ $ok == MISMATCH ]] && echo fail || echo unk; } )
        [[ -f "$RUN_DIR/$file" ]] && file_cell="<a href=\"${file}\">${file}</a>" || file_cell="$file"
        extras=''
        rand_file="rand-sampled-${cfg}-${arc}.config"
        randdef_file="randdef-disabled-${cfg}-${arc}.config"
        [[ -f "$RUN_DIR/$rand_file"    ]] && extras="${extras:+$extras }<a href=\"${rand_file}\">rand-sampled</a>"
        [[ -f "$RUN_DIR/$randdef_file" ]] && extras="${extras:+$extras }<a href=\"${randdef_file}\">randdef-disabled</a>"
        [[ -z $extras ]] && extras='—'
        printf '<tr><td>%s</td><td>%s</td><td style="font-size:.85em">%s</td><td class="%s">%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$cfg" "$arc" "$sha" "$ok_cls" "$ok" "$file_cell" "$extras"
    done

    printf '</table>\n<h2 style="font-size:1em;margin-top:1.5em">All report files</h2>\n'
    printf '<table>\n<tr><th>Config</th><th>Arch</th><th>dmesg</th><th>build log</th><th>QEMU log</th><th>kconfig</th><th>Extras</th></tr>\n'
    for row in "${ROWS[@]}"; do
        IFS='|' read -r cfg arc bld bt tp tt kp kf ts dur fr ftests <<< "$row"
        _dmesg="dmesg-${cfg}-${arc}.txt"
        _blog="build-${cfg}-${arc}.log"
        _qlog="qemu-${cfg}-${arc}.log"
        _kconf="kconfig-${cfg}-${arc}.config"
        _rands="rand-sampled-${cfg}-${arc}.config"
        _randdef="randdef-disabled-${cfg}-${arc}.config"
        _lnk() { local f="$1" l="${2:-$1}"; [[ -f "$RUN_DIR/$f" ]] && printf '<a href="%s">%s</a>' "$f" "$l" || printf '—'; }
        dmesg_c=$(_lnk "$_dmesg" dmesg)
        blog_c=$(_lnk "$_blog" build.log)
        qlog_c=$(_lnk "$_qlog" qemu.log)
        kconf_c=$(_lnk "$_kconf" kconfig)
        extras=''
        [[ -f "$RUN_DIR/$_rands"   ]] && extras="${extras:+$extras }<a href=\"${_rands}\">rand-sampled</a>"
        [[ -f "$RUN_DIR/$_randdef" ]] && extras="${extras:+$extras }<a href=\"${_randdef}\">randdef-disabled</a>"
        [[ -z $extras ]] && extras='—'
        printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$cfg" "$arc" "$dmesg_c" "$blog_c" "$qlog_c" "$kconf_c" "$extras"
    done

    cat << HTMLFOOT
</table>
</body>
</html>
HTMLFOOT
} > "$HTML"

# ── Done ──────────────────────────────────────────────────────────────────────

info "Report written: $RUN_DIR/"
info "  summary.mail.txt — $MAIL"
info "  summary.txt  — $TXT"
info "  summary.html — $HTML"
for crow in "${CONFIG_ROWS[@]}"; do
    IFS='|' read -r cfg arc sha file ok <<< "$crow"
    info "  Config $cfg/$arc  [sha256:${sha:0:16}...]  $RUN_DIR/$file  [$ok]"
done
printf '\nOverall result: %s  (duration: %s)\n' "$OVERALL" "$OVERALL_DURATION"
cat "$TXT"

# ── Regression diff ───────────────────────────────────────────────────────────

_DIFF="$(dirname "$0")/diff.sh"

# Auto-diff vs previous run (second-to-last dir by sort order)
mapfile -t _prev_runs < <(find "$REPORT_DIR" -maxdepth 1 -mindepth 1 -type d \
    ! -name baseline | sort)
_prev=''
for _d in "${_prev_runs[@]}"; do
    [[ $(basename "$_d") == $(basename "$RUN_DIR") ]] && continue
    _prev="$_d"
done
if [[ -n $_prev ]]; then
    printf '\n'
    info "Diff vs previous run ($(basename "$_prev")):"
    "$_DIFF" "$_prev" "$RUN_DIR" "$RUN_DIR/diff-prev.txt" || true
fi

# Also diff vs pinned baseline when set
if [[ -L "$REPORT_DIR/baseline" ]]; then
    _base=$(readlink -f "$REPORT_DIR/baseline" 2>/dev/null || true)
    _base="${_base%/}"
    _curr=$(readlink -f "$RUN_DIR" 2>/dev/null || echo "$RUN_DIR")
    if [[ -n $_base && -d $_base && $_base != "$_curr" ]]; then
        printf '\n'
        info "Diff vs baseline ($(basename "$_base")):"
        "$_DIFF" "$_base" "$RUN_DIR" "$RUN_DIR/diff-baseline.txt" || true
    fi
fi

[[ $OVERALL == PASS ]] || exit 1
