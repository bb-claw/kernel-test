/* ns-uts: UTS namespace regression tests.
 * Subcommands:
 *   clone           — unshare CLONE_NEWUTS, verify inode change + hostname isolation
 *   setns <path>    — open ns file, setns, verify inode matches target
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
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
	unsigned long before = ns_inode("/proc/self/ns/uts");
	if (before == 0) {
		fprintf(stderr, "stat /proc/self/ns/uts: %s\n", strerror(errno));
		return 1;
	}
	if (unshare(CLONE_NEWUTS) < 0) {
		fprintf(stderr, "unshare CLONE_NEWUTS: %s\n", strerror(errno));
		return 1;
	}
	unsigned long after = ns_inode("/proc/self/ns/uts");
	if (before == after) {
		fprintf(stderr, "inode unchanged after unshare (%lu)\n", before);
		return 1;
	}
	if (sethostname("ns-uts-test", 11) < 0) {
		fprintf(stderr, "sethostname: %s\n", strerror(errno));
		return 1;
	}
	char buf[64] = {0};
	gethostname(buf, sizeof(buf) - 1);
	if (strcmp(buf, "ns-uts-test") != 0) {
		fprintf(stderr, "hostname mismatch: got '%s'\n", buf);
		return 1;
	}
	printf("clone: inode %lu->%lu hostname ok\n", before, after);
	return 0;
}

static int cmd_setns(const char *ns_path)
{
	unsigned long target = ns_inode(ns_path);
	if (target == 0) {
		fprintf(stderr, "stat %s: %s\n", ns_path, strerror(errno));
		return 1;
	}
	int fd = open(ns_path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", ns_path, strerror(errno));
		return 1;
	}
	if (setns(fd, CLONE_NEWUTS) < 0) {
		fprintf(stderr, "setns: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	close(fd);
	unsigned long got = ns_inode("/proc/self/ns/uts");
	if (got != target) {
		fprintf(stderr, "setns: inode mismatch target=%lu got=%lu\n", target, got);
		return 1;
	}
	printf("setns: inode %lu matches\n", got);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: ns-uts clone|setns <path>\n");
		return 1;
	}
	if (!strcmp(argv[1], "clone"))
		return cmd_clone();
	if (!strcmp(argv[1], "setns") && argc == 3)
		return cmd_setns(argv[2]);
	fprintf(stderr, "unknown command: %s\n", argv[1]);
	return 1;
}
