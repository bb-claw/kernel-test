#!/bin/bash
# Prints one log line in the standard format for Makefile orchestration messages.
# _LOG_START is exported by the Makefile so elapsed is relative to make start.
set -euo pipefail
. "$(dirname "$0")/common.sh"
info "$*"
