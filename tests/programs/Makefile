# Top-level convenience target: build all test programs.
# Calls each program's own Makefile; used by tests/ci/test-*.sh and locally.

.PHONY: all clean arena-test perf-event serial-capture syscall-tests snapshot

all: arena-test perf-event serial-capture syscall-tests snapshot

arena-test:
	$(MAKE) -C arena-test

perf-event:
	$(MAKE) -C perf-event

serial-capture:
	$(MAKE) -C serial-capture

syscall-tests:
	$(MAKE) -C syscall-tests

snapshot:
	$(MAKE) -C snapshot

clean:
	$(MAKE) -C arena-test clean
	$(MAKE) -C perf-event clean
	$(MAKE) -C serial-capture clean
	$(MAKE) -C syscall-tests clean
	$(MAKE) -C snapshot clean
