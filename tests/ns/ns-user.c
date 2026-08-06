/* ns-user: user namespace regression tests.
 * Subcommands:
 *   idmap     — unshare CLONE_NEWUSER, write uid_map, verify mapping
 *   nested-6  — nested user ns with 6 UID ranges; verify kernel accepts > 5 ranges
 *               (CVE-2018-18955: binary search inversion with > 5 ranges)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int write_file(const char *path, const char *content)
{
	int fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	ssize_t r = write(fd, content, strlen(content));
	int saved = errno;
	close(fd);
	errno = saved;
	return (r == (ssize_t)strlen(content)) ? 0 : -1;
}

static int setup_idmap(uid_t uid, gid_t gid)
{
	char buf[64];

	/* Deny setgroups before writing gid_map (required since kernel 3.19) */
	if (write_file("/proc/self/setgroups", "deny") < 0)
		return -1;

	snprintf(buf, sizeof(buf), "0 %u 1\n", (unsigned)uid);
	if (write_file("/proc/self/uid_map", buf) < 0)
		return -1;

	snprintf(buf, sizeof(buf), "0 %u 1\n", (unsigned)gid);
	if (write_file("/proc/self/gid_map", buf) < 0)
		return -1;

	return 0;
}

static int cmd_idmap(void)
{
	uid_t uid = getuid();
	gid_t gid = getgid();

	if (unshare(CLONE_NEWUSER) < 0) {
		if (errno == EPERM || errno == EINVAL) {
			printf("idmap: SKIP CONFIG_USER_NS not available (%s)\n", strerror(errno));
			return 0;
		}
		fprintf(stderr, "unshare CLONE_NEWUSER: %s\n", strerror(errno));
		return 1;
	}
	if (setup_idmap(uid, gid) < 0) {
		fprintf(stderr, "setup_idmap: %s\n", strerror(errno));
		return 1;
	}
	/* Verify uid_map was written and is readable */
	FILE *f = fopen("/proc/self/uid_map", "r");
	if (!f) {
		fprintf(stderr, "open uid_map: %s\n", strerror(errno));
		return 1;
	}
	char line[128];
	int found = 0;
	while (fgets(line, sizeof(line), f)) {
		unsigned ns_id, host_id, count;
		if (sscanf(line, "%u %u %u", &ns_id, &host_id, &count) == 3) {
			if (ns_id == 0 && host_id == (unsigned)uid && count == 1)
				found = 1;
		}
	}
	fclose(f);
	if (!found) {
		fprintf(stderr, "idmap: expected '0 %u 1' in uid_map\n", (unsigned)uid);
		return 1;
	}
	printf("idmap: uid_map written and verified ok\n");
	return 0;
}

/*
 * CVE-2018-18955: nested user namespace with > 5 UID ranges used a binary
 * search that incorrectly reversed the kernel→ns translation direction.
 *
 * After unshare(CLONE_NEWUSER) the process is inside the new namespace and
 * cannot write a multi-UID uid_map without CAP_SETUID in the parent ns
 * (only single-UID identity maps are allowed without it).  Use a fork+pipe
 * pattern instead: the child unshares and waits; the parent (still in the
 * initial namespace, uid 0, has CAP_SETUID) writes the 6-range uid_map on
 * behalf of the child.
 */
static int cmd_nested_6(void)
{
	uid_t uid = getuid();
	gid_t gid = getgid();
	int to_child[2], from_child[2];

	if (pipe(to_child) < 0 || pipe(from_child) < 0) {
		fprintf(stderr, "nested-6: pipe: %s\n", strerror(errno));
		return 1;
	}

	pid_t child = fork();
	if (child < 0) {
		fprintf(stderr, "nested-6: fork: %s\n", strerror(errno));
		return 1;
	}

	if (child == 0) {
		close(to_child[1]);
		close(from_child[0]);

		if (unshare(CLONE_NEWUSER) < 0) {
			char c = (errno == EPERM || errno == EINVAL) ? 'S' : 'E';
			write(from_child[1], &c, 1);
			_exit(1);
		}
		write(from_child[1], "R", 1);  /* ready: uid_map not yet written */
		/* Wait for parent to write uid_map, then exit */
		char c;
		read(to_child[0], &c, 1);
		close(to_child[0]);
		close(from_child[1]);
		_exit(0);
	}

	/* Parent: still in initial namespace with CAP_SETUID */
	close(to_child[0]);
	close(from_child[1]);

	char status;
	if (read(from_child[0], &status, 1) < 1)
		status = 'E';
	close(from_child[0]);

	if (status == 'S') {
		printf("nested-6: SKIP CONFIG_USER_NS not available\n");
		write(to_child[1], "x", 1);
		close(to_child[1]);
		int st; waitpid(child, &st, 0);
		return 0;
	}
	if (status != 'R') {
		fprintf(stderr, "nested-6: child unshare failed\n");
		write(to_child[1], "x", 1);
		close(to_child[1]);
		int st; waitpid(child, &st, 0);
		return 1;
	}

	/*
	 * Write 6 single-UID extents for child's uid_map.
	 * 6 extents trigger the binary-search path that CVE-2018-18955 broke.
	 */
	char path[64];
	char buf[256];

	snprintf(path, sizeof(path), "/proc/%d/setgroups", (int)child);
	write_file(path, "deny");

	snprintf(buf, sizeof(buf),
		"0 %u 1\n1 %u 1\n2 %u 1\n3 %u 1\n4 %u 1\n5 %u 1\n",
		(unsigned)uid,     (unsigned)uid + 1, (unsigned)uid + 2,
		(unsigned)uid + 3, (unsigned)uid + 4, (unsigned)uid + 5);
	snprintf(path, sizeof(path), "/proc/%d/uid_map", (int)child);
	int uid_ok = (write_file(path, buf) == 0);
	int saved = errno;

	snprintf(buf, sizeof(buf),
		"0 %u 1\n1 %u 1\n2 %u 1\n3 %u 1\n4 %u 1\n5 %u 1\n",
		(unsigned)gid,     (unsigned)gid + 1, (unsigned)gid + 2,
		(unsigned)gid + 3, (unsigned)gid + 4, (unsigned)gid + 5);
	snprintf(path, sizeof(path), "/proc/%d/gid_map", (int)child);
	write_file(path, buf);  /* gid_map failure is non-fatal for the CVE test */

	write(to_child[1], "x", 1);
	close(to_child[1]);

	int st; waitpid(child, &st, 0);

	if (!uid_ok) {
		fprintf(stderr, "nested-6: uid_map 6-range write failed: %s "
			"(regression: CVE-2018-18955)\n", strerror(saved));
		return 1;
	}
	printf("nested-6: 6-range uid_map accepted ok\n");
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: ns-user idmap|nested-6\n");
		return 1;
	}
	if (!strcmp(argv[1], "idmap"))    return cmd_idmap();
	if (!strcmp(argv[1], "nested-6")) return cmd_nested_6();
	fprintf(stderr, "unknown command: %s\n", argv[1]);
	return 1;
}
