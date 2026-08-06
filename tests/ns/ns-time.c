/* ns-time: time namespace regression tests.
 * Subcommands:
 *   offset    — unshare CLONE_NEWTIME, set CLOCK_MONOTONIC offset, verify
 *   setns-mt  — create a kernel thread, then setns into time ns; must EINVAL
 *               (CVE-2023-23586: io_uring workers bypassed current_is_single_threaded())
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef CLONE_NEWTIME
#define CLONE_NEWTIME 0x00000080
#endif

static int write_file(const char *path, const char *content)
{
	int fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	ssize_t r = write(fd, content, strlen(content));
	close(fd);
	return (r == (ssize_t)strlen(content)) ? 0 : -1;
}

static int cmd_offset(void)
{
	if (unshare(CLONE_NEWTIME) < 0) {
		fprintf(stderr, "unshare CLONE_NEWTIME: %s\n", strerror(errno));
		return 1;
	}
	/* Verify timens_offsets is readable and starts at zero */
	FILE *f = fopen("/proc/self/timens_offsets", "r");
	if (!f) {
		fprintf(stderr, "/proc/self/timens_offsets: %s\n", strerror(errno));
		return 1;
	}
	char line[128];
	int found_monotonic = 0;
	while (fgets(line, sizeof(line), f)) {
		char clock[32];
		long long sec;
		unsigned nsec;
		if (sscanf(line, "%31s %lld %u", clock, &sec, &nsec) == 3) {
			if (!strcmp(clock, "monotonic") && sec == 0 && nsec == 0)
				found_monotonic = 1;
		}
	}
	fclose(f);
	if (!found_monotonic) {
		fprintf(stderr, "offset: timens_offsets missing 'monotonic 0 0' baseline\n");
		return 1;
	}

	/* Set a 100-second offset on CLOCK_MONOTONIC */
	if (write_file("/proc/self/timens_offsets", "monotonic 100 0\n") < 0) {
		fprintf(stderr, "write timens_offsets: %s\n", strerror(errno));
		return 1;
	}

	/*
	 * Fork a child into the time namespace to read the adjusted clock.
	 * Only processes forked after the offset is written see it.
	 */
	pid_t child = fork();
	if (child < 0) {
		fprintf(stderr, "fork: %s\n", strerror(errno));
		return 1;
	}
	if (child == 0) {
		struct timespec ts;
		if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
			_exit(1);
		/* With a +100s offset the time must be at least 100 seconds */
		if (ts.tv_sec < 100) {
			fprintf(stderr, "offset: CLOCK_MONOTONIC=%lld expected >=100\n",
				(long long)ts.tv_sec);
			_exit(1);
		}
		printf("offset: CLOCK_MONOTONIC=%llds (+100s offset applied ok)\n",
		       (long long)ts.tv_sec);
		_exit(0);
	}
	int status;
	waitpid(child, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

/* Thread stack for clone()-based thread */
static char _thread_stack[4096 * 4];

static int thread_fn(void *arg)
{
	(void)arg;
	pause();
	return 0;
}

static int cmd_setns_mt(void)
{
	/*
	 * CVE-2023-23586: io_uring workers (kernel threads sharing a process mm)
	 * bypassed current_is_single_threaded() in commit_nsset() and could call
	 * setns(CLONE_NEWTIME) from a multi-threaded context.
	 *
	 * Note: unshare(CLONE_NEWTIME) is NOT restricted to single-threaded
	 * processes; only setns(CLONE_NEWTIME) enforces this check.
	 *
	 * Test: open a foreign time namespace fd, create a CLONE_THREAD thread
	 * (multi-threaded process), then call setns(fd, CLONE_NEWTIME) — must
	 * return EINVAL.
	 */

	/* Step 1: fork a child that creates a new time namespace to use as target */
	int sync_to[2], sync_from[2];
	if (pipe(sync_to) < 0 || pipe(sync_from) < 0) {
		fprintf(stderr, "setns-mt: pipe: %s\n", strerror(errno));
		return 1;
	}
	pid_t ns_child = fork();
	if (ns_child < 0) {
		fprintf(stderr, "setns-mt: fork: %s\n", strerror(errno));
		return 1;
	}
	if (ns_child == 0) {
		close(sync_to[1]);
		close(sync_from[0]);
		if (unshare(CLONE_NEWTIME) < 0) {
			write(sync_from[1], "E", 1);
			_exit(1);
		}
		write(sync_from[1], "R", 1);  /* ready */
		char c;
		read(sync_to[0], &c, 1);  /* wait for parent to finish */
		_exit(0);
	}
	close(sync_to[0]);
	close(sync_from[1]);

	char ns_status;
	if (read(sync_from[0], &ns_status, 1) < 1)
		ns_status = 'E';
	close(sync_from[0]);

	if (ns_status != 'R') {
		printf("setns-mt: SKIP child unshare(CLONE_NEWTIME) failed\n");
		write(sync_to[1], "x", 1);
		close(sync_to[1]);
		int st; waitpid(ns_child, &st, 0);
		return 0;
	}

	/* Step 2: open the child's time namespace fd (a different time ns) */
	char path[64];
	snprintf(path, sizeof(path), "/proc/%d/ns/time", (int)ns_child);
	int ns_fd = open(path, O_RDONLY | O_CLOEXEC);
	if (ns_fd < 0) {
		fprintf(stderr, "setns-mt: open %s: %s\n", path, strerror(errno));
		write(sync_to[1], "x", 1);
		close(sync_to[1]);
		int st; waitpid(ns_child, &st, 0);
		return 1;
	}

	/* Step 3: create a CLONE_THREAD thread — makes us multi-threaded */
	pid_t tid = clone(thread_fn,
			  _thread_stack + sizeof(_thread_stack),
			  CLONE_VM | CLONE_FS | CLONE_FILES |
			  CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM,
			  NULL);
	if (tid < 0) {
		fprintf(stderr, "setns-mt: clone thread: %s\n", strerror(errno));
		close(ns_fd);
		write(sync_to[1], "x", 1);
		close(sync_to[1]);
		int st; waitpid(ns_child, &st, 0);
		return 1;
	}

	if (syscall(SYS_tgkill, getpid(), tid, 0) < 0) {
		printf("setns-mt: SKIP thread exited before setns test (OOM or race)\n");
		close(ns_fd);
		write(sync_to[1], "x", 1);
		close(sync_to[1]);
		int st; waitpid(ns_child, &st, 0);
		_exit(0);
	}

	/* Step 4: attempt setns from multi-threaded process — must fail EINVAL */
	int ret = setns(ns_fd, CLONE_NEWTIME);
	int saved_errno = errno;

	int thread_alive = (syscall(SYS_tgkill, getpid(), tid, 0) == 0);

	close(ns_fd);

	/*
	 * Print result before _exit().  The CLONE_THREAD thread shares our
	 * process and is killed when we call _exit() — do NOT kill it with
	 * SIGKILL first, as that also kills the calling thread before output
	 * can be flushed.
	 */
	int exit_code;
	if (ret == 0) {
		if (!thread_alive) {
			printf("setns-mt: SKIP thread died before setns (race, not CVE)\n");
			exit_code = 0;
		} else {
			fprintf(stderr,
				"setns-mt: setns(CLONE_NEWTIME) succeeded from multi-threaded "
				"process (regression: CVE-2023-23586 style bypass)\n");
			exit_code = 1;
		}
	} else if (saved_errno != EINVAL && saved_errno != EUSERS) {
		/*
		 * kernel/time/namespace.c:timens_install() returns EUSERS (not EINVAL)
		 * when current_is_single_threaded() fails.
		 */
		fprintf(stderr, "setns-mt: expected EINVAL/EUSERS got %d (%s)\n",
			saved_errno, strerror(saved_errno));
		exit_code = 1;
	} else {
		printf("setns-mt: setns(CLONE_NEWTIME) correctly denied (%s) from "
		       "multi-threaded process ok\n", strerror(saved_errno));
		exit_code = 0;
	}
	fflush(stdout);
	fflush(stderr);

	write(sync_to[1], "x", 1);
	close(sync_to[1]);
	int st; waitpid(ns_child, &st, 0);
	/* _exit terminates the CLONE_THREAD thread too */
	_exit(exit_code);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: ns-time offset|setns-mt\n");
		return 1;
	}
	if (!strcmp(argv[1], "offset"))   return cmd_offset();
	if (!strcmp(argv[1], "setns-mt")) return cmd_setns_mt();
	fprintf(stderr, "unknown command: %s\n", argv[1]);
	return 1;
}
