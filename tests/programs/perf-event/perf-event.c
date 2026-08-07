/*
 * perf-event: minimal perf_event_open test binary.
 * Opens PERF_TYPE_SOFTWARE / PERF_COUNT_SW_TASK_CLOCK, burns a short loop,
 * reads the counter, prints it, and exits 0 if the count is > 0.
 * Works in QEMU TCG (no hardware PMU required).
 */
#include <linux/perf_event.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

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

	if (read(fd, &count, sizeof(count)) != (ssize_t)sizeof(count)) {
		perror("read");
		close(fd);
		return 1;
	}
	close(fd);

	printf("%llu\n", (unsigned long long)count);
	return count > 0 ? 0 : 1;
}
