/*
 * snapshot — on-board system snapshot dumper
 *
 * Runs at boot, collects kernel state, writes a compact structured report to
 * stdout. /init redirects stdout to /tmp/snapshot.txt before the test loop.
 *
 * Output format: one "** SNAPSHOT **" header, then one "LABEL: value" line
 * per field. Exit code: 0 = clean, 1-254 = issue count, 255 = infra failure.
 *
 * Fields collected:
 *   HOSTNAME      gethostname(2)
 *   UNAME         uname(2) — sysname/nodename/release/version/machine
 *   INIT          /proc/1/comm — init process name
 *   UPTIME        /proc/uptime — formatted as Xd Xh Xm Xs
 *   LOADAVG       /proc/loadavg — raw line
 *   MEMORY        /proc/meminfo — total/free/avail kB
 *   KERNELMEM     /proc/meminfo — slab/sunreclaim/kstack kB
 *   HUGEPAGES     /proc/meminfo — total hugepages + page size kB
 *   SWAP          /proc/meminfo — total/used kB
 *   PAGESIZE      sysconf(_SC_PAGESIZE)
 *   CPU           /proc/cpuinfo — model name + core count
 *   FLAGS         /proc/cpuinfo — known ISA flags present (avx, lse, …)
 *   CLOCKSOURCE   /sys/devices/system/clocksource/…/current_clocksource
 *   FS            /proc/filesystems — count + cgroup2/btrfs/ext4 presence
 *   USER          getuid() + getpwuid() — username and uid
 *   LSM           /sys/kernel/security/lsm — active security modules
 *   ASLR          /proc/sys/kernel/randomize_va_space
 *   DMESG_RESTRICT /proc/sys/kernel/dmesg_restrict
 *   KPTR_RESTRICT /proc/sys/kernel/kptr_restrict
 *   SCHEDSTATS    /proc/sys/kernel/sched_schedstats (skipped if absent)
 *   CGROUP_CTRL   /sys/fs/cgroup/cgroup.controllers (skipped if absent)
 *   ENTROPY       /proc/sys/kernel/random/entropy_avail
 *   #MODULES      /proc/modules — loaded module count
 *   TAINTED       /proc/sys/kernel/tainted
 *   DMESG         klogctl — oops/bugs/warns/panics/rcu_stall/hung_task/oom_kill/lockup/kunit_fail
 *   ISSUES        total issue count (taint + hard dmesg events)
 *   CMDLINE       /proc/cmdline
 */

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/klog.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>

#define KLOG_READ_ALL 3
#define KLOG_SIZE_BUFFER 10

#define PROC_UPTIME "/proc/uptime"
#define PROC_CMDLINE "/proc/cmdline"
#define PROC_SYS_KERNEL_TAINTED "/proc/sys/kernel/tainted"
#define PROC_SYS_KERNEL_ASLR "/proc/sys/kernel/randomize_va_space"
#define PROC_SYS_KERNEL_DMESG_RESTRICT "/proc/sys/kernel/dmesg_restrict"
#define PROC_SYS_KERNEL_KPTR_RESTRICT "/proc/sys/kernel/kptr_restrict"
#define PROC_MEMINFO "/proc/meminfo"
#define PROC_LOADAVG "/proc/loadavg"
#define PROC_MODULES "/proc/modules"
#define PROC_CPUINFO "/proc/cpuinfo"
#define PROC_FILESYSTEMS "/proc/filesystems"
#define PROC_INIT "/proc/1/comm"
#define PROC_SYS_KERNEL_SCHEDSTATS "/proc/sys/kernel/sched_schedstats"
#define PROC_SYS_RANDOM_ENTROPY_AVAIL "/proc/sys/kernel/random/entropy_avail"
#define SYS_CGROUP_CONTROLLERS "/sys/fs/cgroup/cgroup.controllers"
#define SYS_KERNEL_SECURITY_LSM "/sys/kernel/security/lsm"
#define SYS_CURRENT_CLOCKSOURCE \
	"/sys/devices/system/clocksource/clocksource0/current_clocksource"

static int fail_count = 0;
static int issue_count = 0;

static void header(const char *msg)
{
	printf("\n** %s **\n", msg);
}

static void print_result(const char *section, const char *result)
{
	printf("%15s: %s", section, result);
}
static void fail(const char *operation, const char *resource, const char *msg)
{
	printf("FAIL: %s %s: %s\n", operation, resource, msg);
	fail_count++;
}

static void fail_errno(const char *operation, const char *resource, int err)
{
	printf("FAIL: %s %s: %s\n", operation, resource, strerror(err));
	fail_count++;
}

static void close_fd(int *fd)
{
	if (*fd >= 0)
		close(*fd);
}

static int try_read_file(const char *path, char *buf, size_t size)
{
	int fd __attribute__((cleanup(close_fd))) = -1;
	ssize_t n;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	n = read(fd, buf, size - 1);
	if (n <= 0)
		return -1;
	buf[n] = '\0';
	return 0;
}

static void dump_hostname(void)
{
	char hostname[64];
	char str[66];
	if (gethostname(hostname, sizeof(hostname)) != 0) {
		fail_errno("syscall", "hostname", errno);
		return;
	}

	snprintf(str, sizeof(str), "%s\n", hostname);
	print_result("HOSTNAME", str);
}

static void dump_uname(void)
{
	struct utsname u;
	char str[512];
	if (uname(&u) != 0) {
		fail_errno("syscall", "uname", errno);
		return;
	}

	snprintf(str, sizeof(str), "%s %s %s %s %s\n", u.sysname, u.nodename,
		 u.release, u.version, u.machine);
	print_result("UNAME", str);
}

static void dump_uptime(void)
{
	char buf[64];
	char str[64];
	double uptime_sec;
	long sec, days, hours, minutes, seconds;

	if (try_read_file(PROC_UPTIME, buf, sizeof(buf)) != 0)
		return;
	if (sscanf(buf, "%lf", &uptime_sec) != 1) {
		fail("parse", PROC_UPTIME, "unexpected format");
		return;
	}
	sec = (long)uptime_sec;
	days = sec / 86400;
	hours = (sec % 86400) / 3600;
	minutes = (sec % 3600) / 60;
	seconds = sec % 60;
	if (days > 0) {
		snprintf(str, sizeof(str), "%ldd %ldh %ldm %lds\n", days, hours,
			 minutes, seconds);
	} else {
		snprintf(str, sizeof(str), "%ldh %ldm %lds\n", hours, minutes,
			 seconds);
	}
	print_result("UPTIME", str);
}

static void dump_cmdline(void)
{
	char buf[256];
	if (try_read_file(PROC_CMDLINE, buf, sizeof(buf)) == 0) {
		print_result("CMDLINE", buf);
	}
}

static void dump_tainted(void)
{
	static const struct {
		int bit;
		const char *name;
		int is_issue; /* 1 = kernel misbehaviour; 0 = administrative/load-time fact */
	} flags[] = {
		{ 0, "PROPRIETARY_MODULE", 0 },
		{ 1, "FORCED_MODULE", 0 },
		{ 2, "CPU_OUT_OF_SPEC", 0 },
		{ 3, "FORCED_RMMOD", 0 },
		{ 4, "MACHINE_CHECK", 1 },
		{ 5, "BAD_PAGE", 1 },
		{ 6, "USER", 0 },
		{ 7, "DIE", 1 },
		{ 8, "OVERRIDDEN_ACPI_TABLE", 0 },
		{ 9, "WARN", 1 },
		{ 10, "STAGING_DRIVER", 0 },
		{ 11, "FIRMWARE_WORKAROUND", 0 },
		{ 12, "OOT_MODULE", 0 },
		{ 13, "UNSIGNED_MODULE", 0 },
		{ 14, "SOFTLOCKUP", 1 },
		{ 15, "LIVEPATCH", 0 },
		{ 16, "AUX_TAINT", 0 },
		{ 17, "RANDSTRUCT", 0 },
		{ 18, "TEST", 0 },
		{ 19, "FWCTL", 0 },
	};
	char raw[32];
	char str[512];
	char *end;
	long tainted;
	size_t i, slen;
	int first;

	if (try_read_file(PROC_SYS_KERNEL_TAINTED, raw, sizeof(raw)) != 0)
		return;

	tainted = strtol(raw, &end, 10);
	if (end == raw) {
		print_result("TAINTED", raw);
		return;
	}

	if (tainted == 0) {
		print_result("TAINTED", "0\n");
		return;
	}

	for (i = 0; i < sizeof(flags) / sizeof(flags[0]); i++) {
		if (flags[i].is_issue && (tainted & (1L << flags[i].bit)))
			issue_count++;
	}

	slen = (size_t)snprintf(str, sizeof(str), "%ld (", tainted);
	first = 1;
	for (i = 0; i < sizeof(flags) / sizeof(flags[0]); i++) {
		if (!(tainted & (1L << flags[i].bit)))
			continue;
		if (!first && slen < sizeof(str) - 2)
			str[slen++] = ' ';
		slen += (size_t)snprintf(str + slen, sizeof(str) - slen, "%s",
					 flags[i].name);
		first = 0;
	}
	if (slen < sizeof(str) - 2)
		str[slen++] = ')';
	if (slen < sizeof(str) - 1)
		str[slen++] = '\n';
	str[slen] = '\0';

	print_result("TAINTED", str);
}

static void dump_issues(void)
{
	char str[16];
	snprintf(str, sizeof(str), "%d\n", issue_count);
	print_result("ISSUES", str);
}

static void dump_security(void)
{
	char buf[32];

	if (try_read_file(PROC_SYS_KERNEL_ASLR, buf, sizeof(buf)) == 0)
		print_result("ASLR", buf);
	else
		print_result("ASLR", "n/a");
	if (try_read_file(PROC_SYS_KERNEL_DMESG_RESTRICT, buf, sizeof(buf)) == 0)
		print_result("DMESG_RESTRICT", buf);
	else
		print_result("DMESG_RESTRICT", "n/a");
	if (try_read_file(PROC_SYS_KERNEL_KPTR_RESTRICT, buf, sizeof(buf)) == 0)
		print_result("KPTR_RESTRICT", buf);
	else
		print_result("KPTR_RESTRICT", "n/a");
}

static void dump_lsm(void)
{
	char buf[128];
	char str[130];

	if (try_read_file(SYS_KERNEL_SECURITY_LSM, buf, sizeof(buf)) == 0) {
		snprintf(str, sizeof(str), "%s\n", buf);
		print_result("LSM", str);
	}
}

static void dump_clocksource(void)
{
	char buf[128];

	if (try_read_file(SYS_CURRENT_CLOCKSOURCE, buf, sizeof(buf)) == 0)
		print_result("CLOCKSOURCE", buf);
	else
		print_result("CLOCKSOURCE", "n/a");
}

static void dump_pagesize(void)
{
	char str[64];
	long pagesize = 0;
	if ((pagesize = sysconf(_SC_PAGESIZE)) < 0) {
		fail_errno("syscall", "pagesize", errno);
		return;
	}

	snprintf(str, sizeof(str), "%ld\n", pagesize);
	print_result("PAGESIZE", str);
}

static void dump_dmesg(void)
{
	char str[256];
	char *buf;
	char *line;
	int len;
	int oops = 0, bugs = 0, warns = 0, panics = 0;
	int rcu_stall = 0, hung_task = 0, oom_kill = 0, lockup = 0,
	    kunit_fail = 0;

	len = klogctl(KLOG_SIZE_BUFFER, NULL, 0);
	if (len < 0) {
		if (errno == EPERM)
			print_result("DMESG", "skip: CAP_SYSLOG required\n");
		else
			fail_errno("klogctl", "KLOG_SIZE_BUFFER", errno);
		return;
	}

	buf = (char *)malloc((size_t)len + 1);
	if (!buf) {
		fail("malloc", "dmesg buffer", "out of memory");
		return;
	}

	len = klogctl(KLOG_READ_ALL, buf, len);
	if (len < 0) {
		fail_errno("klogctl", "KLOG_READ_ALL", errno);
		free(buf);
		return;
	}
	buf[len] = '\0';

	line = buf;
	while (*line != '\0') {
		char *nl = strchr(line, '\n');
		if (nl)
			*nl = '\0';
		if (strstr(line, "Oops:"))
			oops++;
		if (strstr(line, "BUG: soft lockup") ||
		    strstr(line, "BUG: hard lockup"))
			lockup++;
		else if (strstr(line, "BUG:"))
			bugs++;
		if (strstr(line, "WARNING:"))
			warns++;
		if (strstr(line, "Kernel panic"))
			panics++;
		if (strstr(line, "self-detected stall"))
			rcu_stall++;
		if (strstr(line, "blocked for more than"))
			hung_task++;
		if (strstr(line, "Out of memory: Killed process"))
			oom_kill++;
		{
			const char *p = strstr(line, "not ok ");
			if (p && (p[7] >= '0' && p[7] <= '9'))
				kunit_fail++;
		}
		if (!nl)
			break;
		line = nl + 1;
	}

	free(buf);

	issue_count += oops + bugs + panics + rcu_stall + hung_task + oom_kill +
		       lockup + kunit_fail;

	snprintf(
		str, sizeof(str),
		"oops=%d bugs=%d warns=%d panics=%d rcu_stall=%d hung_task=%d oom_kill=%d lockup=%d kunit_fail=%d\n",
		oops, bugs, warns, panics, rcu_stall, hung_task, oom_kill,
		lockup, kunit_fail);
	print_result("DMESG", str);
}

static void dump_meminfo(void)
{
	char buf[4096];
	char *line;
	char key[64];
	char memstr[256];
	char swapstr[64];
	long value;
	long mem_total = 0, mem_free = 0, mem_avail = 0;
	long slab = 0, sunreclaim = 0, kstack = 0;
	long swap_total = 0, swap_free = 0;
	long hugepages_total = 0, hugepage_size = 0;
	size_t klen;

	if (try_read_file(PROC_MEMINFO, buf, sizeof(buf)) != 0)
		return;

	line = buf;
	while (*line != '\0') {
		char *nl = strchr(line, '\n');
		if (nl)
			*nl = '\0';

		if (sscanf(line, "%63s %ld kB", key, &value) == 2) {
			klen = strlen(key);
			if (klen > 0 && key[klen - 1] == ':')
				key[klen - 1] = '\0';

			if (strcmp(key, "MemTotal") == 0)
				mem_total = value;
			else if (strcmp(key, "MemFree") == 0)
				mem_free = value;
			else if (strcmp(key, "MemAvailable") == 0)
				mem_avail = value;
			else if (strcmp(key, "Slab") == 0)
				slab = value;
			else if (strcmp(key, "SUnreclaim") == 0)
				sunreclaim = value;
			else if (strcmp(key, "KernelStack") == 0)
				kstack = value;
			else if (strcmp(key, "HugePages_Total") == 0)
				hugepages_total = value;
			else if (strcmp(key, "Hugepagesize") == 0)
				hugepage_size = value;
			else if (strcmp(key, "SwapTotal") == 0)
				swap_total = value;
			else if (strcmp(key, "SwapFree") == 0)
				swap_free = value;
		}

		if (!nl)
			break;
		line = nl + 1;
	}

	snprintf(memstr, sizeof(memstr), "total=%ld free=%ld avail=%ld kB\n",
		 mem_total, mem_free, mem_avail);
	print_result("MEMORY", memstr);

	snprintf(memstr, sizeof(memstr),
		 "slab=%ld sunreclaim=%ld kstack=%ld kB\n", slab, sunreclaim,
		 kstack);
	print_result("KERNELMEM", memstr);

	snprintf(memstr, sizeof(memstr), "total=%ld size=%ld\n",
		 hugepages_total, hugepage_size);
	print_result("HUGEPAGES", memstr);

	snprintf(swapstr, sizeof(swapstr), "total=%ld used=%ld kB\n",
		 swap_total, swap_total - swap_free);
	print_result("SWAP", swapstr);
}

static void dump_loadavg(void)
{
	char buf[128];
	if (try_read_file(PROC_LOADAVG, buf, sizeof(buf)) == 0) {
		print_result("LOADAVG", buf);
	}
}

static void dump_modules_count(void)
{
	int fd __attribute__((cleanup(close_fd))) = -1;
	char buf[4096];
	ssize_t n;
	int count, i;
	char str[20];

	fd = open(PROC_MODULES, O_RDONLY);
	if (fd < 0)
		return;

	count = 0;
	while ((n = read(fd, buf, sizeof(buf))) > 0) {
		for (i = 0; i < (int)n; i++) {
			if (buf[i] == '\n')
				count++;
		}
	}
	if (n < 0)
		return;

	snprintf(str, sizeof(str), "%d\n", count);
	print_result("#MODULES", str);
}

static void dump_cpu(void)
{
	int fd __attribute__((cleanup(close_fd))) = -1;
	char buf[4096];
	char linebuf[256];
	char model[128] = "";
	char str[160];
	ssize_t n;
	int cores = 0;
	int linelen = 0;
	int i;

	fd = open(PROC_CPUINFO, O_RDONLY);
	if (fd < 0)
		return;

	while ((n = read(fd, buf, sizeof(buf))) > 0) {
		for (i = 0; i < (int)n; i++) {
			char c = buf[i];
			if (c == '\n') {
				linebuf[linelen] = '\0';
				if (strncmp(linebuf, "processor", 9) == 0) {
					cores++;
				} else if (model[0] == '\0' &&
					   (strncmp(linebuf, "model name",
						    10) == 0 ||
					    strncmp(linebuf, "uarch", 5) ==
						    0)) {
					char *val = strchr(linebuf, ':');
					if (val && val[1] == ' ')
						snprintf(model, sizeof(model),
							 "%s", val + 2);
				}
				linelen = 0;
			} else if (linelen < (int)sizeof(linebuf) - 1) {
				linebuf[linelen++] = c;
			}
		}
	}
	if (n < 0)
		return;

	if (model[0] == '\0')
		snprintf(model, sizeof(model), "unknown");

	snprintf(str, sizeof(str), "%s  cores=%d\n", model, cores);
	print_result("CPU", str);
}

static void dump_cpu_flags(void)
{
	int fd __attribute__((cleanup(close_fd))) = -1;
	char buf[4096];
	char linebuf[4096]; /* flags line can be 500+ chars on x86 */
	char str[256];
	ssize_t n = 0;
	int linelen = 0;
	int done = 0;
	int i, j;

	static const char *const want[] = {
		/* x86 / i386 */
		"avx", "avx2", "aes", "rdrand", "smep", "smap",
		/* arm64 */
		"fp", "asimd", "lse", "sve", "mte", NULL
	};

	fd = open(PROC_CPUINFO, O_RDONLY);
	if (fd < 0)
		return;

	str[0] = '\0';
	while (!done && (n = read(fd, buf, sizeof(buf))) > 0) {
		for (i = 0; i < (int)n && !done; i++) {
			char c = buf[i];
			if (c != '\n') {
				if (linelen < (int)sizeof(linebuf) - 1)
					linebuf[linelen++] = c;
				continue;
			}
			linebuf[linelen] = '\0';
			linelen = 0;

			if (strncmp(linebuf, "flags", 5) != 0 &&
			    strncmp(linebuf, "Features", 8) != 0)
				continue;

			for (j = 0; want[j] != NULL; j++) {
				char needle[34];
				char *pos;
				size_t nlen;
				char after;
				size_t slen;

				snprintf(needle, sizeof(needle), " %s",
					 want[j]);
				nlen = strlen(needle);
				pos = strstr(linebuf, needle);
				if (!pos)
					continue;
				after = pos[nlen];
				if (after != ' ' && after != '\0')
					continue;

				slen = strlen(str);
				if (slen > 0 && slen < sizeof(str) - 2)
					str[slen++] = ' ';
				snprintf(str + slen, sizeof(str) - slen, "%s",
					 want[j]);
			}
			done = 1;
		}
	}
	if (n < 0)
		return;

	if (str[0] == '\0')
		snprintf(str, sizeof(str), "n/a\n");
	else
		snprintf(str + strlen(str), sizeof(str) - strlen(str), "\n");
	print_result("FLAGS", str);
}

static void dump_filesystems(void)
{
	int fd __attribute__((cleanup(close_fd))) = -1;
	char buf[4096];
	char linebuf[64];
	char str[128];
	ssize_t n;
	int linelen = 0;
	int count = 0;
	int has_cgroup2 = 0, has_btrfs = 0, has_ext4 = 0;
	int i;

	fd = open(PROC_FILESYSTEMS, O_RDONLY);
	if (fd < 0)
		return;

	while ((n = read(fd, buf, sizeof(buf))) > 0) {
		for (i = 0; i < (int)n; i++) {
			char c = buf[i];
			if (c == '\n') {
				linebuf[linelen] = '\0';
				count++;
				if (strstr(linebuf, "cgroup2"))
					has_cgroup2 = 1;
				if (strstr(linebuf, "btrfs"))
					has_btrfs = 1;
				if (strstr(linebuf, "ext4"))
					has_ext4 = 1;
				linelen = 0;
			} else if (linelen < (int)sizeof(linebuf) - 1) {
				linebuf[linelen++] = c;
			}
		}
	}
	if (n < 0)
		return;

	snprintf(str, sizeof(str), "count=%d cgroup2=%d btrfs=%d ext4=%d\n",
		 count, has_cgroup2, has_btrfs, has_ext4);
	print_result("FS", str);
}

static void dump_user(void)
{
	char str[64];
	uid_t uid = getuid();
	struct passwd *pw = getpwuid(uid);

	if (pw)
		snprintf(str, sizeof(str), "%s uid=%d\n", pw->pw_name,
			 (int)uid);
	else
		snprintf(str, sizeof(str), "uid=%d\n", (int)uid);
	print_result("USER", str);
}

static void dump_init(void)
{
	char buf[32];

	if (try_read_file(PROC_INIT, buf, sizeof(buf)) == 0)
		print_result("INIT", buf);
}

static void dump_schedstats(void)
{
	char buf[32];

	if (try_read_file(PROC_SYS_KERNEL_SCHEDSTATS, buf, sizeof(buf)) == 0)
		print_result("SCHEDSTATS", buf);
}

static void dump_cgroup_controllers(void)
{
	char buf[256];

	if (try_read_file(SYS_CGROUP_CONTROLLERS, buf, sizeof(buf)) == 0)
		print_result("CGROUP_CTRL", buf);
}

static void dump_entropy(void)
{
	char buf[32];

	if (try_read_file(PROC_SYS_RANDOM_ENTROPY_AVAIL, buf, sizeof(buf)) == 0)
		print_result("ENTROPY", buf);
}

int main(void)
{
	header("SNAPSHOT");
	dump_hostname();
	dump_uname();
	dump_init();
	dump_uptime();
	dump_loadavg();
	dump_meminfo();
	dump_pagesize();
	dump_cpu();
	dump_cpu_flags();
	dump_clocksource();
	dump_filesystems();
	dump_user();
	dump_lsm();
	dump_security();
	dump_schedstats();
	dump_cgroup_controllers();
	dump_entropy();
	dump_modules_count();
	dump_tainted();
	dump_dmesg();
	dump_cmdline();
	dump_issues();

	if (fail_count != 0)
		exit(255);
	if (issue_count > 254)
		exit(254);
	exit(issue_count);
}
