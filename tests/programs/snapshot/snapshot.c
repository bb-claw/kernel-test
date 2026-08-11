/*
 * snapshot — on-board system snapshot dumper
 *
 * Runs at boot, collects kernel state, writes a compact structured report to
 * stdout. /init redirects stdout to /tmp/snapshot.txt before the test loop.
 *
 * Output format: sections separated by "=== NAME ===" headers, followed by
 * a trailing "snapshot_ok=1" line (written only on clean exit).
 *
 * Implementation guide (implement one tier at a time):
 *
 * Tier 1 — start here:
 *   dump_uname()    uname(2) → struct utsname; print sysname/release/machine
 *   dump_uptime()   open + read /proc/uptime; print the raw line
 *   dump_cmdline()  open + read /proc/cmdline; print the raw line
 *   dump_tainted()  open + read /proc/sys/kernel/tainted; print the integer
 *
 * Tier 2 — next:
 *   dump_dmesg()    syslog(SYSLOG_ACTION_SIZE_BUFFER) → allocate buf →
 *                   syslog(SYSLOG_ACTION_READ_ALL, buf, len) → write buf
 *   dump_meminfo()  open + read /proc/meminfo; print the whole file
 *
 * Tier 3 — once v1 works:
 *   dump_loadavg()  open + read /proc/loadavg; print the raw line
 *   dump_modules()  open + read /proc/modules; print the whole file
 *
 * Helpers you will need:
 *   section(name)   prints "=== name ===" header — already implemented
 *   read_file(path) reads a file into a buffer — implement as a helper
 *
 * Useful headers:
 *   #include <sys/utsname.h>   for struct utsname + uname()
 *   #include <sys/syslog.h>    for syslog() + SYSLOG_ACTION_* constants
 *   #include <fcntl.h>         for open() + O_RDONLY
 *   #include <unistd.h>        for read() + close()
 */

#include <stdio.h>

static void section(const char *name)
{
    printf("=== %s ===\n", name);
}

/* TODO Tier 1: replace with uname(2) implementation */
static void dump_uname(void)
{
    section("UNAME");
    printf("TODO: call uname(2) and print sysname/release/machine\n");
}

/* TODO Tier 1: replace with /proc/uptime read */
static void dump_uptime(void)
{
    section("UPTIME");
    printf("TODO: read /proc/uptime\n");
}

/* TODO Tier 1: replace with /proc/cmdline read */
static void dump_cmdline(void)
{
    section("CMDLINE");
    printf("TODO: read /proc/cmdline\n");
}

/* TODO Tier 1: replace with /proc/sys/kernel/tainted read */
static void dump_tainted(void)
{
    section("TAINTED");
    printf("TODO: read /proc/sys/kernel/tainted\n");
}

/* TODO Tier 2: replace with syslog(SYSLOG_ACTION_READ_ALL) implementation */
static void dump_dmesg(void)
{
    section("DMESG");
    printf("TODO: call syslog(SYSLOG_ACTION_READ_ALL)\n");
}

/* TODO Tier 2: replace with /proc/meminfo read */
static void dump_meminfo(void)
{
    section("MEMINFO");
    printf("TODO: read /proc/meminfo\n");
}

/* TODO Tier 3: replace with /proc/loadavg read */
static void dump_loadavg(void)
{
    section("LOADAVG");
    printf("TODO: read /proc/loadavg\n");
}

/* TODO Tier 3: replace with /proc/modules read */
static void dump_modules(void)
{
    section("MODULES");
    printf("TODO: read /proc/modules\n");
}

int main(void)
{
    section("SNAPSHOT");
    dump_uname();
    dump_uptime();
    dump_cmdline();
    dump_tainted();
    dump_dmesg();
    dump_meminfo();
    dump_loadavg();
    dump_modules();
    printf("snapshot_ok=1\n");
    return 0;
}
