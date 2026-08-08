/* ns-net: network namespace regression tests.
 * Subcommands:
 *   clone     — unshare CLONE_NEWNET, verify inode change
 *   proc-net  — verify /proc/net/dev has no host interfaces leaking into new ns
 */
#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned long ns_inode(const char *path)
{
	struct stat st;
	return (stat(path, &st) == 0) ? (unsigned long)st.st_ino : 0;
}

static int cmd_clone(void)
{
	unsigned long before = ns_inode("/proc/self/ns/net");
	if (before == 0) {
		fprintf(stderr, "stat /proc/self/ns/net: %s\n", strerror(errno));
		return 1;
	}
	if (unshare(CLONE_NEWNET) < 0) {
		fprintf(stderr, "unshare CLONE_NEWNET: %s\n", strerror(errno));
		return 1;
	}
	unsigned long after = ns_inode("/proc/self/ns/net");
	if (before == after) {
		fprintf(stderr, "inode unchanged after unshare (%lu)\n", before);
		return 1;
	}
	printf("clone: inode %lu->%lu ok\n", before, after);
	return 0;
}

/*
 * Per-namespace admin tunnel base devices created by built-in drivers.
 * When a tunnel driver is CONFIG_*=y (built-in rather than =m), the kernel
 * creates one of these devices in every new network namespace — they are NOT
 * init_net interfaces leaking in.  Whitelist them so randdefconfig (which
 * forces modules off, turning =m into =y) does not produce false positives.
 */
static const char * const perns_admin_ifaces[] = {
	"lo:", "sit0:", "ip6tnl0:", "ip_vti0:", "ip6gre0:",
	"gre0:", "gretap0:", "ip6erspan0:", "erspan0:", NULL,
};

static int is_perns_admin_iface(const char *line)
{
	for (int i = 0; perns_admin_ifaces[i]; i++)
		if (strstr(line, perns_admin_ifaces[i]))
			return 1;
	return 0;
}

static int cmd_proc_net(void)
{
	if (unshare(CLONE_NEWNET) < 0) {
		fprintf(stderr, "unshare CLONE_NEWNET: %s\n", strerror(errno));
		return 1;
	}
	FILE *f = fopen("/proc/net/dev", "r");
	if (!f) {
		fprintf(stderr, "/proc/net/dev: %s\n", strerror(errno));
		return 1;
	}
	/*
	 * /proc/net/dev: 2 header lines, then one line per interface.
	 * A fresh net ns should only have lo plus optional per-namespace admin
	 * tunnel devices (sit0, ip6tnl0, etc.) created by built-in drivers.
	 */
	char line[256];
	int headers = 0, data_lines = 0;
	int found_lo = 0, found_host = 0;
	char host_iface[64] = "";
	while (fgets(line, sizeof(line), f)) {
		if (headers < 2) { headers++; continue; }
		data_lines++;
		if (!is_perns_admin_iface(line)) {
			found_host = 1;
			if (!host_iface[0]) {
				/* capture first unexpected interface name */
				const char *p = line;
				while (*p == ' ') p++;
				int i = 0;
				while (*p && *p != ':' && i < (int)sizeof(host_iface) - 1)
					host_iface[i++] = *p++;
				host_iface[i] = '\0';
			}
		} else if (strstr(line, "lo:")) {
			found_lo = 1;
		}
	}
	fclose(f);

	if (found_host) {
		fprintf(stderr,
			"proc-net: host interface '%s' visible in new net ns "
			"(regression: init_net leak)\n", host_iface);
		return 1;
	}
	printf("proc-net: %d interface(s), lo=%d, no host leak ok\n",
	       data_lines, found_lo);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: ns-net clone|proc-net\n");
		return 1;
	}
	if (!strcmp(argv[1], "clone"))    return cmd_clone();
	if (!strcmp(argv[1], "proc-net")) return cmd_proc_net();
	fprintf(stderr, "unknown command: %s\n", argv[1]);
	return 1;
}
