# Can pi-durable be bundled into one JS file?

Resolves issue #3 (map: #1). Researched 2026-10-30.

## Answer

**Yes.** `@earendil-works/pi-durable@1.4.0` bundles with esbuild into one ESM file that runs on plain Node with no `node_modules`. No native addons, no dynamic requires, no esbuild warnings.

- **Minified size:** about 0.68 MB with one provider (Anthropic) and in-memory, JSONL or `node:sqlite` storage. About 1.29 MB with all 42 built-in providers.
- **Native modules:** none block bundling. The only `.node`/`.wasm` files in the dependency tree (`quickjs-wasi`, `@silvia-odwyer/photon`) belong to optional features and were tree-shaken out. They are absent from the bundle.
- **Storage:** `node:sqlite` is a Node built-in (no native dependency) and works. JSONL storage is pure Node `fs` and works. `MemoryStorage` needs neither.
- **Minimum Node:** pi-durable declares `>=22.19.0`. The bundle itself needs Node 22 or later (`Promise.withResolvers`). `node:sqlite` needs 22.13 or later. Verified on 22.12, 22.19 and 24.22.
- **Output format:** ESM only, in practice. pi-durable and pi-ai are ESM-only (`"type": "module"`, only `import` conditions), and a CJS bundle only matters if the entry avoids top-level `await`. Emit `.mjs`.
- **Recommendation for nvimpi:** use `MemoryStorage`. The map's standing decision is one-shot requests with no persistence, so SQLite and JSONL add nothing. It also removes the `node:sqlite` experimental warning and the 22.13 floor.

## Experiment

Run on macOS arm64, Node v24.22.1, npm 11.19.1, esbuild 0.28.2. Everything ran in fresh temp dirs outside the repo.

1. `npm init -y && npm i @earendil-works/pi-durable@1.4.0 esbuild` in an empty dir.
2. Entry points (each registers the Anthropic provider, calls `Harness.open(...)` and `harness.root(...)`, then closes), one per storage backend:
   - `MemoryStorage` from the package root.
   - `openNodeSqliteStorage` from `@earendil-works/pi-durable/storage/sqlite/node`.
   - `openNodeJsonlStorage` from `@earendil-works/pi-durable/storage/jsonl/node`.
3. An end-to-end entry using pi-ai's `fauxProvider()` (scripted, in-process, no network), `node:sqlite` storage, `submit()`, `wait()` and reading the answer.
4. `esbuild <entry> --bundle --platform=node --format=esm --target=node22 [--minify]`.
5. Copied the `.mjs` files to a separate empty dir (no `node_modules`, no `package.json`) and ran them with `node`.

### Results

| Entry | Unminified | Minified | Loads from empty dir (Node 24.22.1) |
|---|---|---|---|
| Memory storage | 1.71 MB | 675 KB | yes |
| `node:sqlite` storage | 1.72 MB | 688 KB | yes, creates the `.sqlite` file |
| JSONL storage | 1.79 MB | 713 KB | yes, writes `main.jsonl` and `doc-*.jsonl` |
| End-to-end (faux provider, sqlite, submit and read answer) | n/a | 696 KB | yes, `status: done`, answer text returned |
| All 42 built-in providers (`providers/all`) | n/a | 1.29 MB | yes |

Minified contents of the end-to-end bundle, by package (esbuild metafile): `@anthropic-ai/sdk` 218 KB, `pi-durable` 159 KB, `typebox` 143 KB, `pi-ai` 90 KB, `chord` 51 KB, everything else under 10 KB each.

What was not exercised: a real network call to a provider (the task said no real LLM calls), and reading `~/.pi/agent/auth.json`. The faux provider proves the harness, storage, task scheduler and submission path work inside the bundle. The provider SDKs are bundled and load, but their HTTP path was not run.

### Blockers checked

- **Native modules.** The full install (`npm ls --all`: 93 packages, 113 MB `node_modules`, with `@aws-sdk` and `@smithy` at 7 MB each and `openai` at 28 MB) contains only two non-JS binaries: `quickjs-wasi/quickjs.wasm` and `@silvia-odwyer/photon/photon_rs_bg.wasm`. Both back optional features (code mode, images). The memory/sqlite/jsonl entries do not import them, and the minified bundle contains zero references to `photon` or `quickjs`. Importing `@earendil-works/pi-durable/codemode` or `/images` would pull them in and need separate handling (wasm loading), so don't.
- **Install scripts.** Only `@google/genai` (a no-op `echo`) and `protobufjs` (postinstall). Irrelevant once bundled.
- **Dynamic requires/imports.** The bundle's external references are all Node built-ins: `node:path`, `node:fs`, `node:fs/promises`, `node:crypto`, `node:child_process`, `node:os`, `node:util`, `node:stream`, `node:readline`, plus `node:sqlite` (sqlite entry) and `node:url` (JSONL entry). esbuild emitted no warnings. The `*.lazy.js` modules in pi-ai (`await import(...)`) are for image and classifier features that the bundled path does not reach.
- **Top-level await.** `pi-durable`'s own entry points are fine, but my entries used top-level `await`, which esbuild refuses for `--format=cjs`. This is a limit of my test entries, not of the library. An async `main()` would permit CJS, but ESM is the natural fit.

### Minimum Node version, tested

Minified bundles, run from an empty dir:

| Node | Memory | JSONL | `node:sqlite` | Notes |
|---|---|---|---|---|
| 20.19.0 | fails | not run | not run | `TypeError: Promise.withResolvers is not a function` |
| 22.12.0 | ok | ok | fails | `ERR_UNKNOWN_BUILTIN_MODULE: node:sqlite` |
| 22.19.0 | ok | ok | ok | prints `ExperimentalWarning: SQLite is an experimental feature` |
| 24.22.1 | ok | ok | ok | no warning |

The `engines` field of pi-durable, chord, pi-ai, pi-codemode and pi-telemetry is `>=22.19.0` in every case. Treat 22.19.0 as the supported floor; the sub-22.19 results above show where it breaks, not where it is supported.

## Dependency tree (for reference; not needed at runtime after bundling)

`@earendil-works/pi-durable@1.4.0` has 7 direct dependencies: `diff`, `typebox`, `@silvia-odwyer/photon`, and the Earendil packages `chord`, `pi-ai`, `pi-codemode`, `pi-telemetry`. `pi-ai` brings in the provider SDKs (`@anthropic-ai/sdk`, `openai`, `@google/genai`, `@aws-sdk/client-bedrock-runtime`, `@smithy/node-http-handler`, proxy agents). Total: 93 packages in the tree, 113 MB on disk, 3.5 MB unpacked for pi-durable alone. The bundle carries about 0.6% of that.

## Caveats

- pi-durable is labelled **Experimental: "The API changes without notice between releases."** Pin the exact version (the entry point names and `Harness`/`MemoryStorage` API shapes above are from 1.4.0) and rebuild the bundle deliberately on upgrade.
- `node:sqlite` is Stability 1.2 (release candidate) in Node 24 docs since v24.15.0, and was "no longer behind a flag but still experimental" from v22.13.0. Another reason to avoid it.
- JSONL storage keeps the whole history in memory (pi-durable README, Storage section), which is irrelevant for one-shot use but another reason to prefer `MemoryStorage`.
- The committed bundle will contain the Anthropic SDK 218 KB for one provider. If nvimpi wants provider choice via `setup()`, bundling all providers costs about 1.29 MB minified, and the same trade (smaller file vs. any provider works) belongs in the provider-config ticket.

## Sources

- pi-durable README (Installation, Quick Start, Persist and Resume, Storage; the experimental warning; the note that the package root loads TypeBox and that a tree-shaken bundle uses about 4 MB peak RSS instead of about 23 MB): `README.md` shipped in `@earendil-works/pi-durable@1.4.0` on npm (repo: github.com/earendil-works/pi, `packages/durable`).
- pi-durable `package.json` (`engines.node >=22.19.0`, `exports` map including `./storage/sqlite/node`, `./storage/jsonl/node`, `"type": "module"`): `npm view @earendil-works/pi-durable@1.4.0`.
- Node `engines` of chord, pi-ai, pi-codemode, pi-telemetry (all `>=22.19.0`): each package's `package.json` in the installed tree.
- `openNodeSqliteStorage` delegates to `@earendil-works/chord/sqlite/node`; no native addon, uses `node:sqlite`: `dist/storage/sqlite/node.js` in pi-durable 1.4.0.
- pi-ai Faux Provider section (`fauxProvider()`): `README.md` in `@earendil-works/pi-ai@1.4.0`.
- `node:sqlite` history and stability (added v22.5.0; unflagged v22.13.0 and v23.4.0 but still experimental; release candidate from v24.15.0): [Node v24.22.1 docs JSON](https://nodejs.org/download/release/v24.22.1/docs/api/sqlite.json); [Node v22.13.0 docs JSON](https://nodejs.org/download/release/v22.13.0/docs/api/sqlite.json) (stability 1.1, active development).
- Experiment results: produced locally, as described under Experiment.
