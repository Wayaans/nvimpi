# Sidecar cold start per request

Resolves issue #5 (map: #1). Measured 2026-10-30.

## Answer

**Spawn a fresh sidecar per request.** A cold, bundled sidecar goes from `vim.system` spawn to the provider request leaving in about **89 ms** (median), and to the result back in Lua in about **96 ms**. That is far under the ~300 ms threshold, and it disappears behind a real LLM round trip (typically seconds).

With every provider bundled, the figures are 129 ms and 138 ms, still well under the threshold.

## Numbers

Apple M1 Pro, macOS, Node v24.22.1, Neovim 0.12.6. N=20 per row after one discarded warm-up run. Times in ms.

### One provider (Anthropic), 685 KB minified bundle

| Measure | min | median | p90 | max |
|---|---|---|---|---|
| Bare `node -e ''` spawn and exit | 27.5 | 28.8 | 29.8 | 31.3 |
| Cold: spawn to `ready` line | 53.8 | 55.3 | 57.3 | 57.9 |
| **Cold: spawn to request at server** | 87.5 | **89.2** | 93.1 | 94.7 |
| Cold: spawn to result in Lua | 94.2 | 96.0 | 100.4 | 102.6 |
| Warm (long-lived): write to request at server | 0.9 | 1.5 | 2.5 | 2.6 |
| Warm (long-lived): write to result in Lua | 1.5 | 2.4 | 3.6 | 3.7 |

### All providers (`builtinModels()`), 2.6 MB minified bundle

| Measure | min | median | p90 | max |
|---|---|---|---|---|
| Cold: spawn to `ready` line | 101.6 | 103.6 | 106.5 | 108.9 |
| **Cold: spawn to request at server** | 126.4 | **128.7** | 131.2 | 136.7 |
| Cold: spawn to result in Lua | 134.9 | 137.5 | 140.1 | 145.8 |
| Warm (long-lived): write to result in Lua | 1.7 | 2.3 | 4.5 | 5.5 |

`builtinModels()` pulls in the full model catalog, so this bundle is 2.6 MB, larger than the 1.29 MB `providers/all` import measured in the bundling research. Its cost is roughly 40 ms of extra parse time.

## What a long-lived process would save

About 90 to 135 ms per request, once. Against an LLM call of one to several seconds, that is under 10%. In exchange it would need lifecycle code in Lua: lazy start, restart after a crash, request ids to match concurrent replies, and a kill on `VimLeavePre`. Spawning per request keeps the Lua side to spawn, write one line, and read one line.

## Caveats

- One fast machine. A machine 2 to 3 times slower would put the one-provider bundle at about 180 to 270 ms and the all-providers bundle near 300 ms. If the build bundles every provider, it can recover time with Node's compile cache (`module.enableCompileCache()`, Node 22.1+). That was not measured.
- Node 24 only. Node 22.19 (the floor) was not timed.
- The provider HTTP call went to a local mock (the sidecar's `fetch` was redirected), so the numbers exclude DNS, TLS and the model's latency. They measure exactly the overhead that spawn per request adds.
- Measured from `nvim --headless -l` with `vim.system`, the plugin's real spawn path. A loaded editor with many plugins was not tried.

## How it was measured

The files are in `docs/research/sidecar-cold-start/`:

- `sidecar.ts`: throwaway sidecar. Imports pi-durable, prints `{"type":"ready"}`, then for each NDJSON request line runs the one-shot call from the one-shot API research (`MemoryStorage`, retries and compaction off) and prints the result.
- `mock.mjs`: fake Anthropic Messages endpoint on `127.0.0.1:8787`. It replies over SSE with its arrival time (epoch ms) as the answer text, so Lua can compute spawn to request arrival with one clock.
- `measure.lua`: spawns the bundled sidecar with `vim.system`, sends the request as soon as `ready` arrives, and records the timings. A warm run sends 20 requests to one process.

Reproduce in a scratch directory:

```sh
npm i --ignore-scripts @earendil-works/pi-durable@1.4.0 @earendil-works/pi-ai@1.4.0 @earendil-works/chord@1.4.0 esbuild
npx esbuild sidecar.ts --bundle --platform=node --format=esm --target=node22 --minify --outfile=/tmp/nvimpi-coldstart/run/sidecar.mjs
node mock.mjs &
nvim --headless -l measure.lua
```

For the all-providers variant, replace the `createModels()` and `anthropicProvider()` lines with `builtinModels()` from `@earendil-works/pi-ai/providers/all`.
