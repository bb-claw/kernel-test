/*
 * perf-event: minimal perf_event_open test binary.
 * Opens PERF_TYPE_SOFTWARE / PERF_COUNT_SW_TASK_CLOCK, burns a short loop,
 * reads the counter, prints it, and exits 0 if the count is > 0.
 * Works in QEMU TCG (no hardware PMU required).
 */
#include <sys/syscall.h>
#include <sched.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* Minimal perf_event ABI — avoids linux/perf_event.h kernel-header dependency.
 * musl-gcc does not search /usr/include, so the installed linux-libc-dev header
 * is unreachable.  These three definitions are stable kernel ABI (since 2.6.31). */
#define PERF_TYPE_SOFTWARE        1U
#define PERF_COUNT_SW_TASK_CLOCK  1ULL

struct perf_event_attr {
    uint32_t type;
    uint32_t size;
    uint64_t config;
    uint8_t  pad[120]; /* remaining fields unused; size field informs kernel */
};

int main(void)
{
	struct perf_event_attr attr;
	uint64_t count = 0;
	int fd;
	volatile int i;

	memset(&attr, 0, sizeof(attr));
	attr.type   = PERF_TYPE_SOFTWARE;
	attr.config = PERF_COUNT_SW_TASK_CLOCK;
	attr.size   = sizeof(attr);

	fd = (int)syscall(SYS_perf_event_open, &attr, 0, -1, -1, 0);
	if (fd < 0) {
		perror("perf_event_open");
		return 1;
	}

	for (i = 0; i < 100000; i++) {}

	/* Force a scheduler pass so update_curr() commits sum_exec_runtime.
	 * Without CONFIG_HIGH_RES_TIMERS, task accounting only updates on ticks
	 * (HZ=250 → 4 ms); the loop finishes in <1 ms and TASK_CLOCK reads 0. */
	sched_yield();

	if (read(fd, &count, sizeof(count)) != (ssize_t)sizeof(count)) {
		perror("read");
		close(fd);
		return 1;
	}
	close(fd);

	printf("%llu\n", (unsigned long long)count);
	return count > 0 ? 0 : 1;
}
