#!/bin/sh
# Fake sidecar for the Lua tests: saves the request line, then prints a canned response.
cat > "$NVIMPI_FAKE_REQUEST"
printf '%s\n' "$NVIMPI_FAKE_RESPONSE"
