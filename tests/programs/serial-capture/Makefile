# serial-capture: host-side serial capture tool.
# Captures raw UART bytes to a logfile; used by lib/board.sh (Phase 6+).
# Runs on the test host (x86_64) only — NOT injected into the initramfs.
# Called by lib/bootstrap.sh to build the host binary.

SRC := serial-capture.c
BIN := bin/serial-capture

.PHONY: all clean

all: $(BIN)

$(BIN): $(SRC) | bin
	@printf '[serial-capture] build %s\n' $(BIN)
	gcc -Wall -O2 -std=gnu11 -o $@ $<

bin:
	mkdir -p bin

clean:
	rm -rf bin/
