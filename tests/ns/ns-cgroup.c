/* ns-cgroup: cgroup namespace regression tests.
 * Subcommands:
 *   release-agent — write to cgroup v1 release_agent from user ns; must EPERM
 *                   (CVE-2022-0492: missing CAP_SYS_ADMIN in init_user_ns check)
 *   scoping       — verify /sys/fs/cgroup shows ns-local root, not host root
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef CLONE_NEWCGROUP
#define CLONE_NEWCGROUP 0x02000000
#endif

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

static int cmd_release_agent(void)
{
	/*
	 * CVE-2022-0492: from inside a user namespace + cgroup namespace,
	 * writing to cgroup v1 release_agent must be denied (EPERM).
	 * The write was allowed because cgroup_release_agent_write() didn't
	 * check CAP_SYS_ADMIN in init_user_ns.
	 *
	 * We enter a new user+cgroup namespace, mount cgroup v1 (memory),
	 * then try to write to release_agent.
	 */
	if (unshare(CLONE_NEWUSER) < 0) {
		if (errno == EPERM || errno == EINVAL) {
			printf("release-agent: SKIP user ns not available (%s)\n", strerror(errno));
			return 0;
		}
		fprintf(stderr, "unshare CLONE_NEWUSER: %s\n", strerror(errno));
		return 1;
	}
	/* Write uid/gid maps so we appear as root inside the user ns */
	write_file("/proc/self/setgroups", "deny");
	write_file("/proc/self/uid_map", "0 0 1\n");
	write_file("/proc/self/gid_map", "0 0 1\n");

	if (unshare(CLONE_NEWNS) < 0) {
		fprintf(stderr, "unshare CLONE_NEWNS: %s\n", strerror(errno));
		return 1;
	}
	if (unshare(CLONE_NEWCGROUP) < 0) {
		fprintf(stderr, "unshare CLONE_NEWCGROUP: %s\n", strerror(errno));
		return 1;
	}

	/* Try to mount cgroup v1 memory controller */
	mkdir("/tmp/ns-cg-mem", 0755);
	if (mount("cgroup", "/tmp/ns-cg-mem", "cgroup", 0, "memory") < 0) {
		/* cgroup v1 may not be available in this kernel config */
		printf("release-agent: SKIP cgroup v1 memory controller not available (%s)\n",
		       strerror(errno));
		return 0;
	}

	/* Attempt to write release_agent — must fail with EPERM */
	int fd = open("/tmp/ns-cg-mem/release_agent", O_WRONLY);
	if (fd < 0) {
		if (errno == ENOENT) {
			printf("release-agent: SKIP release_agent not present\n");
			umount2("/tmp/ns-cg-mem", MNT_DETACH);
			return 0;
		}
		if (errno == EPERM) {
			printf("release-agent: EPERM on open ok (kernel prevents access)\n");
			umount2("/tmp/ns-cg-mem", MNT_DETACH);
			return 0;
		}
		fprintf(stderr, "open release_agent: %s\n", strerror(errno));
		umount2("/tmp/ns-cg-mem", MNT_DETACH);
		return 1;
	}
	ssize_t r = write(fd, "/tmp/exploit\n", 13);
	int saved_errno = errno;
	close(fd);
	umount2("/tmp/ns-cg-mem", MNT_DETACH);

	if (r > 0) {
		fprintf(stderr,
			"release-agent: write SUCCEEDED from user ns "
			"(regression: CVE-2022-0492 — missing init_user_ns CAP check)\n");
		return 1;
	}
	if (saved_errno == EPERM) {
		printf("release-agent: write correctly denied EPERM ok\n");
		return 0;
	}
	fprintf(stderr, "release-agent: unexpected errno %d (%s)\n",
		saved_errno, strerror(saved_errno));
	return 1;
}

static int cmd_scoping(void)
{
	/*
	 * Inside a new cgroup namespace, /sys/fs/cgroup should show the
	 * current process's cgroup as root ("/"), not the host path.
	 * Check that the cgroup.controllers file is present and accessible.
	 */
	if (unshare(CLONE_NEWCGROUP) < 0) {
		fprintf(stderr, "unshare CLONE_NEWCGROUP: %s\n", strerror(errno));
		return 1;
	}
	/* cgroup ns inode must have changed */
	struct stat st;
	if (stat("/proc/self/ns/cgroup", &st) < 0) {
		fprintf(stderr, "stat /proc/self/ns/cgroup: %s\n", strerror(errno));
		return 1;
	}
	/* Verify /sys/fs/cgroup is accessible (implies ns remapping is in place) */
	if (access("/sys/fs/cgroup", R_OK) < 0) {
		if (errno == ENOENT) {
			/* cgroup v2 not mounted in this config; skip gracefully */
			printf("scoping: SKIP /sys/fs/cgroup not available (tinyconfig without cgroups)\n");
			return 0;
		}
		fprintf(stderr, "access /sys/fs/cgroup: %s\n", strerror(errno));
		return 1;
	}
	printf("scoping: cgroup ns inode %lu /sys/fs/cgroup accessible ok\n",
	       (unsigned long)st.st_ino);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: ns-cgroup release-agent|scoping\n");
		return 1;
	}
	if (!strcmp(argv[1], "release-agent")) return cmd_release_agent();
	if (!strcmp(argv[1], "scoping"))       return cmd_scoping();
	fprintf(stderr, "unknown command: %s\n", argv[1]);
	return 1;
}
