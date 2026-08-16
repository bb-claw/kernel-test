/* ns-ipc: IPC namespace regression tests.
 * Subcommands:
 *   clone    — unshare CLONE_NEWIPC, verify inode change
 *   semop    — create SysV semaphore in new IPC ns; verify /proc/sysvipc/sem is empty
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned long ns_inode(const char *path)
{
	struct stat st;
	return (stat(path, &st) == 0) ? (unsigned long)st.st_ino : 0;
}

static int cmd_clone(void)
{
	unsigned long before = ns_inode("/proc/self/ns/ipc");
	if (before == 0) {
		fprintf(stderr, "stat /proc/self/ns/ipc: %s\n", strerror(errno));
		return 1;
	}
	if (unshare(CLONE_NEWIPC) < 0) {
		fprintf(stderr, "unshare CLONE_NEWIPC: %s\n", strerror(errno));
		return 1;
	}
	unsigned long after = ns_inode("/proc/self/ns/ipc");
	if (before == after) {
		fprintf(stderr, "inode unchanged after unshare (%lu)\n", before);
		return 1;
	}
	printf("clone: inode %lu->%lu ok\n", before, after);
	return 0;
}

static int cmd_semop(void)
{
	if (unshare(CLONE_NEWIPC) < 0) {
		fprintf(stderr, "unshare CLONE_NEWIPC: %s\n", strerror(errno));
		return 1;
	}
	/* Create a semaphore inside the new IPC namespace */
	int semid = semget(IPC_PRIVATE, 1, IPC_CREAT | 0600);
	if (semid < 0) {
		if (errno == ENOSYS) {
			printf("semop: CONFIG_SYSVIPC=n, skipping\n");
			return 0;
		}
		fprintf(stderr, "semget: %s\n", strerror(errno));
		return 1;
	}
	/* /proc/sysvipc/sem inside this IPC ns should list our semaphore */
	FILE *f = fopen("/proc/sysvipc/sem", "r");
	if (!f) {
		/* CONFIG_SYSVIPC may be off; skip gracefully */
		printf("semop: /proc/sysvipc/sem not available, skipping check\n");
		semctl(semid, 0, IPC_RMID);
		return 0;
	}
	char line[256];
	int found = 0;
	while (fgets(line, sizeof(line), f)) {
		/* Lines contain semid as a decimal field; header line has "key" */
		if (strstr(line, "key"))
			continue;
		found++;
	}
	fclose(f);
	semctl(semid, 0, IPC_RMID);
	/* We created exactly one semaphore — exactly one data line expected */
	if (found != 1) {
		fprintf(stderr, "semop: expected 1 sem in ns, got %d\n", found);
		return 1;
	}
	printf("semop: semaphore isolated in new IPC ns ok\n");
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: ns-ipc clone|semop\n");
		return 1;
	}
	if (!strcmp(argv[1], "clone"))
		return cmd_clone();
	if (!strcmp(argv[1], "semop"))
		return cmd_semop();
	fprintf(stderr, "unknown command: %s\n", argv[1]);
	return 1;
}
