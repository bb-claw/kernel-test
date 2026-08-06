/* ns-net: network namespace regression tests.
 * Subcommands:
 *   clone     — unshare CLONE_NEWNET, verify inode change
 *   proc-net  — verify /proc/net/dev shows only lo (no host interfaces leaking)
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
	 * /proc/net/dev format: 2 header lines, then one line per interface.
	 * In a new network namespace, only lo exists (and it's down).
	 * Count data lines (skip first two header lines).
	 */
	char line[256];
	int headers = 0, data_lines = 0;
	int found_lo = 0, found_other = 0;
	while (fgets(line, sizeof(line), f)) {
		if (headers < 2) { headers++; continue; }
		data_lines++;
		if (strstr(line, "lo:"))
			found_lo = 1;
		else
			found_other = 1;
	}
	fclose(f);

	if (found_other) {
		fprintf(stderr,
			"proc-net: host interfaces visible in new net ns "
			"(regression: init_net leak)\n");
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
