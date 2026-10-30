#!/bin/sh
# Fake `node` for the Lua tests: logs each run to $NVIMPI_FAKE_NODE_LOG and prints
# $NVIMPI_FAKE_NODE_VERSION, as `node --version` would.
echo "$*" >> "$NVIMPI_FAKE_NODE_LOG"
printf '%s\n' "$NVIMPI_FAKE_NODE_VERSION"
