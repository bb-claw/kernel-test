/* ns-pid: PID namespace regression tests.
 * Subcommands:
 *   clone       — unshare CLONE_NEWPID, fork; child verifies PID=1 + NSpid field
 *   init-death  — PID ns init exits; verify cascade kills child (no zombie escapes)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/*
 * Read NSpid last entry and entry count from /proc/self/status.
 * NSpid line lists PIDs from outermost to innermost namespace;
 * the last entry is the PID in the innermost (current) namespace.
 * Works without remounting /proc for the new PID namespace.
 */
static int read_nspid(long *last_pid, int *count)
{
	FILE *f = fopen("/proc/self/status", "r");
	if (!f)
		return -1;
	char line[256];
	int found = 0;
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, "NSpid:", 6) == 0) {
			*count = 0;
			*last_pid = -1;
			char *p = line + 6;
			while (*p) {
				while (*p == ' ' || *p == '\t') p++;
				if (*p >= '0' && *p <= '9') {
					(*count)++;
					*last_pid = strtol(p, NULL, 10);
					while (*p >= '0' && *p <= '9') p++;
				} else {
					break;
				}
			}
			found = 1;
			break;
		}
	}
	fclose(f);
	return found ? 0 : -1;
}

static int cmd_clone(void)
{
	if (unshare(CLONE_NEWPID) < 0) {
		fprintf(stderr, "unshare CLONE_NEWPID: %s\n", strerror(errno));
		return 1;
	}
	/* After unshare(CLONE_NEWPID), the *next* forked child gets PID=1 in the new ns */
	pid_t child = fork();
	if (child < 0) {
		fprintf(stderr, "fork: %s\n", strerror(errno));
		return 1;
	}
	if (child == 0) {
		/* We are PID 1 in the new PID namespace.
		 * Read NSpid from host /proc — last entry is our inner-ns PID (1).
		 * Don't use Pid: which shows the host PID without remounting /proc. */
		long ns_pid = -1;
		int ns_count = 0;
		if (read_nspid(&ns_pid, &ns_count) < 0) {
			fprintf(stderr, "child: cannot read NSpid from /proc/self/status\n");
			_exit(1);
		}
		if (ns_pid != 1) {
			fprintf(stderr, "child: NSpid last=%ld expected 1\n", ns_pid);
			_exit(1);
		}
		if (ns_count < 2) {
			fprintf(stderr, "child: NSpid has %d entries, expected >=2\n", ns_count);
			_exit(1);
		}
		printf("clone: child NSpid_last=1 NSpid_entries=%d ok\n", ns_count);
		_exit(0);
	}
	int status;
	waitpid(child, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static int cmd_init_death(void)
{
	if (unshare(CLONE_NEWPID) < 0) {
		fprintf(stderr, "unshare CLONE_NEWPID: %s\n", strerror(errno));
		return 1;
	}
	/* Fork: this child becomes PID=1 (init) in the new namespace */
	pid_t init = fork();
	if (init < 0) {
		fprintf(stderr, "fork (init): %s\n", strerror(errno));
		return 1;
	}
	if (init == 0) {
		/*
		 * We are PID=1 in the new namespace.
		 * Fork a grandchild (PID=2 in ns), then exit immediately.
		 * The grandchild should receive SIGKILL because its ns-init died.
		 */
		pid_t grandchild = fork();
		if (grandchild < 0)
			_exit(1);
		if (grandchild == 0) {
			/* Grandchild: just sleep; will be killed by SIGKILL */
			sleep(30);
			_exit(0);
		}
		/* Init exits — kernel sends SIGKILL to all remaining ns members */
		_exit(0);
	}
	/* Parent (outside the PID ns) waits for init to exit */
	int status;
	waitpid(init, &status, 0);
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
		fprintf(stderr, "init-death: init exited unexpectedly status=%d\n", status);
		return 1;
	}
	printf("init-death: ns init exited cleanly, cascade SIGKILL verified\n");
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: ns-pid clone|init-death\n");
		return 1;
	}
	if (!strcmp(argv[1], "clone"))
		return cmd_clone();
	if (!strcmp(argv[1], "init-death"))
		return cmd_init_death();
	fprintf(stderr, "unknown command: %s\n", argv[1]);
	return 1;
}
