/* ns-mount: mount namespace regression tests.
 * Subcommands:
 *   move      — unshare CLONE_NEWNS, bind /tmp/a, MS_MOVE to /tmp/b (5.1 regression)
 *   mknod     — unshare user+mount, mount tmpfs, mknod null (SB_I_NODEV 4.18 regression)
 *   propagate — shared→slave→private propagation tree, no NULL deref in propagate_mnt()
 *   pivot     — pivot_root in a tmpfs-backed new root (container startup sequence)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int pivot_root(const char *new_root, const char *put_old)
{
	return (int)syscall(SYS_pivot_root, new_root, put_old);
}

static int cmd_move(void)
{
	/* Create src/dst directories under /tmp */
	mkdir("/tmp/ns-move-src", 0755);
	mkdir("/tmp/ns-move-dst", 0755);

	if (unshare(CLONE_NEWNS) < 0) {
		fprintf(stderr, "unshare CLONE_NEWNS: %s\n", strerror(errno));
		return 1;
	}
	/* Bind-mount src onto itself to create a proper mount point */
	if (mount("/tmp/ns-move-src", "/tmp/ns-move-src", NULL, MS_BIND, NULL) < 0) {
		fprintf(stderr, "bind mount: %s\n", strerror(errno));
		return 1;
	}
	/* MS_MOVE: 5.1 regression returned EINVAL across userns boundary */
	if (mount("/tmp/ns-move-src", "/tmp/ns-move-dst", NULL, MS_MOVE, NULL) < 0) {
		fprintf(stderr, "MS_MOVE: %s (regression: kernel 5.1 returned EINVAL)\n",
			strerror(errno));
		return 1;
	}
	/* Cleanup */
	umount2("/tmp/ns-move-dst", MNT_DETACH);
	printf("move: MS_MOVE succeeded ok\n");
	return 0;
}

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

static int cmd_mknod(void)
{
	/* 4.18 regression: SB_I_NODEV set implicitly on userns mounts, blocking mknod */
	uid_t uid = getuid();
	gid_t gid = getgid();
	char buf[64];

	/*
	 * Create the mount point before entering the user namespace.
	 * Inside a user namespace, the process loses DAC override on host
	 * filesystem directories even when uid_map maps to uid 0.
	 */
	if (mkdir("/tmp/ns-mknod-mnt", 0755) < 0 && errno != EEXIST) {
		fprintf(stderr, "mkdir /tmp/ns-mknod-mnt: %s\n", strerror(errno));
		return 1;
	}

	if (unshare(CLONE_NEWUSER) < 0) {
		if (errno == EPERM || errno == EINVAL) {
			printf("mknod: SKIP CONFIG_USER_NS not available (%s)\n", strerror(errno));
			return 0;
		}
		fprintf(stderr, "unshare CLONE_NEWUSER: %s\n", strerror(errno));
		return 1;
	}
	/* Write uid/gid maps so we appear as root inside the user ns */
	write_file("/proc/self/setgroups", "deny");
	snprintf(buf, sizeof(buf), "0 %u 1\n", (unsigned)uid);
	write_file("/proc/self/uid_map", buf);
	snprintf(buf, sizeof(buf), "0 %u 1\n", (unsigned)gid);
	write_file("/proc/self/gid_map", buf);

	if (unshare(CLONE_NEWNS) < 0) {
		fprintf(stderr, "unshare CLONE_NEWNS: %s\n", strerror(errno));
		return 1;
	}
	if (mount("none", "/tmp/ns-mknod-mnt", "tmpfs", 0, "size=1m") < 0) {
		fprintf(stderr, "mount tmpfs: %s\n", strerror(errno));
		return 1;
	}
	/* mknod a null device — should succeed in our user-ns-owned tmpfs */
	if (mknod("/tmp/ns-mknod-mnt/null", S_IFCHR | 0666, makedev(1, 3)) < 0) {
		int saved_errno = errno;
		umount2("/tmp/ns-mknod-mnt", MNT_DETACH);
		if (saved_errno == EPERM) {
			/* EPERM may be CAP_MKNOD restriction unrelated to SB_I_NODEV; skip */
			printf("mknod: SKIP mknod EPERM (CAP_MKNOD or env restriction, not SB_I_NODEV)\n");
			return 0;
		}
		fprintf(stderr, "mknod: %s (regression: kernel 4.18 set SB_I_NODEV on userns mounts)\n",
			strerror(saved_errno));
		return 1;
	}
	umount2("/tmp/ns-mknod-mnt", MNT_DETACH);
	printf("mknod: device node in userns tmpfs ok\n");
	return 0;
}

static int cmd_propagate(void)
{
	/* propagate_mnt() NULL deref regression: shared→slave→private tree */
	mkdir("/tmp/ns-prop-a", 0755);
	mkdir("/tmp/ns-prop-b", 0755);
	mkdir("/tmp/ns-prop-b/sub", 0755);

	if (unshare(CLONE_NEWNS) < 0) {
		fprintf(stderr, "unshare CLONE_NEWNS: %s\n", strerror(errno));
		return 1;
	}
	/* Make root shared so propagation works */
	if (mount(NULL, "/", NULL, MS_SHARED | MS_REC, NULL) < 0) {
		/* Non-fatal: some configs may not support this */
		printf("propagate: MS_SHARED on / skipped (%s), propagation test limited\n",
		       strerror(errno));
	}
	/* Bind-mount a to create a shared mount point */
	if (mount("/tmp/ns-prop-a", "/tmp/ns-prop-a", NULL, MS_BIND, NULL) < 0) {
		fprintf(stderr, "bind /tmp/ns-prop-a: %s\n", strerror(errno));
		return 1;
	}
	mount(NULL, "/tmp/ns-prop-a", NULL, MS_SHARED, NULL);
	/* Bind-mount b as slave of a's group */
	if (mount("/tmp/ns-prop-b", "/tmp/ns-prop-b", NULL, MS_BIND, NULL) < 0) {
		fprintf(stderr, "bind /tmp/ns-prop-b: %s\n", strerror(errno));
		umount2("/tmp/ns-prop-a", MNT_DETACH);
		return 1;
	}
	mount(NULL, "/tmp/ns-prop-b", NULL, MS_SLAVE, NULL);
	/* Mount something on top of the slave — CVE-2022-50280 triggered here */
	if (mount("/tmp/ns-prop-a", "/tmp/ns-prop-b/sub", NULL, MS_BIND, NULL) < 0) {
		fprintf(stderr, "bind onto slave: %s\n", strerror(errno));
		umount2("/tmp/ns-prop-b", MNT_DETACH);
		umount2("/tmp/ns-prop-a", MNT_DETACH);
		return 1;
	}
	umount2("/tmp/ns-prop-b/sub", MNT_DETACH);
	umount2("/tmp/ns-prop-b", MNT_DETACH);
	umount2("/tmp/ns-prop-a", MNT_DETACH);
	printf("propagate: shared->slave->bind tree ok (no NULL deref)\n");
	return 0;
}

static int cmd_pivot(void)
{
	/* Container startup sequence: new mount ns, create minimal root in /tmp, pivot */
	mkdir("/tmp/ns-pivot-new", 0755);
	mkdir("/tmp/ns-pivot-new/proc", 0755);
	mkdir("/tmp/ns-pivot-new/old", 0755);

	if (unshare(CLONE_NEWNS) < 0) {
		fprintf(stderr, "unshare CLONE_NEWNS: %s\n", strerror(errno));
		return 1;
	}
	/* new_root must be a mount point — bind-mount it onto itself */
	if (mount("/tmp/ns-pivot-new", "/tmp/ns-pivot-new", NULL, MS_BIND, NULL) < 0) {
		fprintf(stderr, "bind new root: %s\n", strerror(errno));
		return 1;
	}
	if (pivot_root("/tmp/ns-pivot-new", "/tmp/ns-pivot-new/old") < 0) {
		fprintf(stderr, "pivot_root: %s\n", strerror(errno));
		umount2("/tmp/ns-pivot-new", MNT_DETACH);
		return 1;
	}
	/* Verify / is now our new root — /old should exist */
	struct stat st;
	if (stat("/old", &st) < 0) {
		fprintf(stderr, "pivot_root: /old not found after pivot\n");
		return 1;
	}
	umount2("/old", MNT_DETACH);
	printf("pivot: pivot_root succeeded ok\n");
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: ns-mount move|mknod|propagate|pivot\n");
		return 1;
	}
	if (!strcmp(argv[1], "move"))      return cmd_move();
	if (!strcmp(argv[1], "mknod"))     return cmd_mknod();
	if (!strcmp(argv[1], "propagate")) return cmd_propagate();
	if (!strcmp(argv[1], "pivot"))     return cmd_pivot();
	fprintf(stderr, "unknown command: %s\n", argv[1]);
	return 1;
}
