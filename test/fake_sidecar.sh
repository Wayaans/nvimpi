#!/bin/sh
# Fake sidecar for the Lua tests: saves the request line, then optionally writes
# $NVIMPI_FAKE_STDERR, sleeps $NVIMPI_FAKE_SLEEP seconds, prints $NVIMPI_FAKE_RESPONSE
# (if set) and exits with $NVIMPI_FAKE_EXIT.
cat > "$NVIMPI_FAKE_REQUEST"
if [ -n "$NVIMPI_FAKE_STDERR" ]; then printf '%s\n' "$NVIMPI_FAKE_STDERR" >&2; fi
# exec so a timeout's TERM reaches the sleeping process and closes the pipes.
if [ -n "$NVIMPI_FAKE_SLEEP" ]; then exec sleep "$NVIMPI_FAKE_SLEEP"; fi
if [ -n "$NVIMPI_FAKE_RESPONSE" ]; then printf '%s\n' "$NVIMPI_FAKE_RESPONSE"; fi
exit "${NVIMPI_FAKE_EXIT:-0}"
