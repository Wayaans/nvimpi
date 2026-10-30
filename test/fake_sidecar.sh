#!/bin/sh
# Fake sidecar for the Lua tests: saves the request line, optionally sleeps, then prints a canned response.
cat > "$NVIMPI_FAKE_REQUEST"
if [ -n "$NVIMPI_FAKE_SLEEP" ]; then
  # Detach sleep from our pipes so a killed fake closes stdout at once.
  sleep "$NVIMPI_FAKE_SLEEP" < /dev/null > /dev/null 2>&1
fi
printf '%s\n' "$NVIMPI_FAKE_RESPONSE"
