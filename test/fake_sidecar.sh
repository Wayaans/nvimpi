#!/bin/sh
# Fake sidecar for the Lua tests: saves the request line, then optionally writes
# $NVIMPI_FAKE_STDERR, sleeps $NVIMPI_FAKE_SLEEP seconds, prints $NVIMPI_FAKE_RESPONSE
# (if set) and exits with $NVIMPI_FAKE_EXIT.
cat > "$NVIMPI_FAKE_REQUEST"
if [ -n "$NVIMPI_FAKE_STDERR" ]; then printf '%s\n' "$NVIMPI_FAKE_STDERR" >&2; fi
if [ -n "$NVIMPI_FAKE_SLEEP" ]; then
  # Detach sleep from our pipes so a killed fake (cancel or timeout) closes stdout at once.
  sleep "$NVIMPI_FAKE_SLEEP" < /dev/null > /dev/null 2>&1
fi
if [ -n "$NVIMPI_FAKE_RESPONSE" ]; then printf '%s\n' "$NVIMPI_FAKE_RESPONSE"; fi
exit "${NVIMPI_FAKE_EXIT:-0}"
