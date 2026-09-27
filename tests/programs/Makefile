# Top-level convenience target: build all test programs.
# Calls each program's own Makefile; used by tests/ci/test-*.sh and locally.

.PHONY: all clean valgrind valgrind-build fmt arena-test perf-event serial-capture syscall-tests snapshot

all: arena-test perf-event serial-capture syscall-tests snapshot

arena-test:
	@$(MAKE) --no-print-directory --silent -C arena-test

perf-event:
	@$(MAKE) --no-print-directory --silent -C perf-event

serial-capture:
	@$(MAKE) --no-print-directory --silent -C serial-capture

syscall-tests:
	@$(MAKE) --no-print-directory --silent -C syscall-tests

snapshot:
	@$(MAKE) --no-print-directory --silent -C snapshot

clean:
	@$(MAKE) --no-print-directory --silent -C arena-test clean
	@$(MAKE) --no-print-directory --silent -C perf-event clean
	@$(MAKE) --no-print-directory --silent -C serial-capture clean
	@$(MAKE) --no-print-directory --silent -C syscall-tests clean
	@$(MAKE) --no-print-directory --silent -C snapshot clean

valgrind-build:
	@$(MAKE) --no-print-directory --silent -C arena-test valgrind-build
	@$(MAKE) --no-print-directory --silent -C perf-event valgrind-build
	@$(MAKE) --no-print-directory --silent -C serial-capture valgrind-build
	@$(MAKE) --no-print-directory --silent -C syscall-tests valgrind-build
	@$(MAKE) --no-print-directory --silent -C snapshot valgrind-build

valgrind: valgrind-build

fmt:
	@$(MAKE) --no-print-directory --silent -C arena-test fmt
	@$(MAKE) --no-print-directory --silent -C perf-event fmt
	@$(MAKE) --no-print-directory --silent -C serial-capture fmt
	@$(MAKE) --no-print-directory --silent -C syscall-tests fmt
	@$(MAKE) --no-print-directory --silent -C snapshot fmt
