#!/bin/bash
# Prints one INFO log line in the standard timestamp format.
# Used by: Makefile orchestration headers ([fetch]/[build]/[programs]/etc.)
#          tests/common.mk and tests/ns/Makefile per-binary summary lines.
# _LOG_START is exported by the Makefile so elapsed is relative to make start.
set -euo pipefail
. "$(dirname "$0")/common.sh"
info "$*"
