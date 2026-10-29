# How pi-ai resolves credentials with and without pi installed

Research for issue #4 (parent map #1). Versions read: `@earendil-works/pi-ai`, `pi-durable`, `chord`, `pi-coding-agent`, all **1.4.0**, fetched with `npm pack` into an empty temp dir and read as data. A local pi 1.4.0 install was also inspected read-only. No secret values were read or recorded; only the structure of `~/.pi/agent/auth.json` (provider ids, credential types, field names).

## Short answer

- pi-durable has **no credential logic of its own**. `Harness.open(storage, { models, ... })` takes a pi-ai `Models` object, and all auth resolution happens in pi-ai.
- pi-ai resolves auth through a `CredentialStore` you inject into `createModels({ credentials })`. With no store, it uses an in-memory one and falls back to **provider env vars** (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, ...).
- The `CredentialStore` interface is public, tiny (4 methods), and its stored shape is **exactly pi's `auth.json` format**. The sidecar can implement it over `auth.json` itself (about 40 lines) with **no import from `pi-coding-agent`**. pi-ai's own OAuth refresh then works unchanged. Verified by experiment (below).
- Without pi installed: env vars work out of the box. OAuth/subscription logins cannot be created without pi (or a login flow in nvimpi), but they can be **reused** if `auth.json` exists.

## 1. How pi-ai resolves credentials

Source: `pi-ai/dist/auth/resolve.js` (`resolveProviderAuth`), `auth/types.d.ts`, `auth/helpers.js`, `README.md` ("Credential Store", "Environment Variables").

Precedence, per provider, in order:

1. **Explicit key** passed per call (`overrides.apiKey`, plus `overrides.env`). Wins over everything if the provider supports API-key auth.
2. **Stored credential** from the `CredentialStore`, keyed by `Provider.id`, one per provider. A stored credential *owns* the provider: env vars are consulted **only when nothing is stored**. There is no silent env fallback after a failed OAuth refresh, or when the stored type has no matching handler (`resolve.js`: it returns `undefined` or throws `ModelsError`).
3. **Ambient sources** via the provider's `ApiKeyAuth.resolve`: env vars, AWS profiles, gcloud ADC.

`getAuth()` resolves `undefined` for an unconfigured provider and rejects with `ModelsError` (`"auth"` or `"oauth"`) when something is actually broken.

### CredentialStore interface (`auth/types.d.ts`)

```ts
interface CredentialStore {
  read(providerId, opts?): Promise<Credential | undefined>;
  list(opts?): Promise<readonly { providerId: string; type: "api_key" | "oauth" }[]>;
  modify(providerId, fn: (current?: Credential) => Promise<Credential | undefined>, opts?): Promise<Credential | undefined>;
  delete(providerId, opts?): Promise<void>;
}
type Credential =
  | { type: "api_key"; key?: string; env?: Record<string, string> }
  | { type: "oauth"; access: string; refresh: string; expires: number; [k: string]: unknown };
```

The doc comment states this is "the shape of today's auth.json". `modify` is the only write path and must be a serialized read-modify-write ("cross-process too where the backing store supports it, e.g. a file lock"). Methods reject only on storage failure. Read-only or best-effort stores are explicitly valid.

pi-ai ships only `InMemoryCredentialStore` (`auth/credential-store.js`, the default in `createModels`: `options?.credentials ?? new InMemoryCredentialStore()`). "Apps inject persistent stores."

### Env vars per provider

`README.md` "Environment Variables" lists them (Node only). Highlights: `ANTHROPIC_API_KEY` (or `ANTHROPIC_OAUTH_TOKEN`; `anthropic.js` also honors `ANTHROPIC_AUTH_TOKEN` as a bearer header and workload-identity federation vars), `OPENAI_API_KEY`, `GEMINI_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`, `MISTRAL_API_KEY`, `XAI_API_KEY`, `DEEPSEEK_API_KEY`, `OPENCODE_API_KEY`, `COPILOT_GITHUB_TOKEN` (pi docs `providers.md`). Some providers need several (Azure: key plus base URL or resource name; Cloudflare: key, account id, gateway id; Vertex: key or project plus location plus ADC; Bedrock: AWS credential chain). The standard helper is `envApiKeyAuth(name, envVars)`: stored `credential.key` wins, else the first set env var.

Note the table is per provider, so nvimpi's configured provider id decides which env var is read. nvimpi should not hardcode the table; pi-ai owns it.

## 2. Can the sidecar read pi's `auth.json` itself?

**Yes, without importing `pi-coding-agent` internals.**

### What pi-coding-agent exposes

- `pi-coding-agent` `exports` are only `.` and `./rpc-entry` (`package.json`). Deep imports are not possible.
- Its `AuthStorage` (the `CredentialStore` over `auth.json`) is **not exported** from the root. `CHANGELOG.md`: "`AuthStorage` and its storage backends are no longer exported; use `ModelRuntime` (or a custom pi-ai `CredentialStore`), or `readStoredCredential()` for one-off reads of auth.json."
- Root does export `readStoredCredential(providerId, authPath?)` (sync, one-off read, no refresh) and `ModelRuntime`. Importing the root pulls in the entire coding agent (tui, mcp, codemode, ~20 deps), which breaks the "lightweight, one bundled file" goal. Not recommended.

### The file format (`auth-storage.js`, `docs/providers.md`, local file structure)

- Path: `<agent-dir>/auth.json`, where agent-dir is `$PI_CODING_AGENT_DIR` (tilde expanded) or `~/.pi/agent` (`config.js` `getAgentDir`; the env name is `${APP_NAME.toUpperCase()}_CODING_AGENT_DIR`).
- Content: one JSON object, `{ [providerId]: Credential }`, UTF-8 possibly with a BOM (pi strips it). File mode `0600`, written under `proper-lockfile` (lock on the file path, 30 s stale).
- Local file (structure only): three entries, `opencode-go` (`api_key`: `type,key`), `anthropic` (`api_key`: `type,key`), `openai-codex` (`oauth`: `type,access,refresh,expires,accountId`). So extra OAuth fields such as `accountId` exist; the `[k: string]: unknown` index signature carries them and a store must **round-trip unknown fields**.
- Provider ids match pi-ai `Provider.id` (`anthropic`, `openai-codex`, `opencode-go`, ...). Renames happen across releases (CHANGELOG: `azure-openai-responses` became `azure`, users had to rename the key). So the file format is stable-ish but not frozen; pi-ai's `Credential` type is the contract.
- **API-key `key` is not always a literal.** pi's `resolveConfigValue` (`resolve-config-value.js`) treats `key` as: `!command` (run in shell, stdout cached), `$ENV` / `${ENV}` interpolation (`$$` and `$!` escape), otherwise literal. The pi-ai `envApiKeyAuth` does **not** do this; it uses `credential.key` verbatim. So a custom store that wants parity with pi must resolve it in `read()`, as pi's `AuthStorage.read` and `ReadOnlyAuthStorage.read` do. Per pi docs the command runs once and is cached. `list()` must never run commands.
- `api_key.env` holds provider-scoped config (Cloudflare account/gateway ids, Azure, Vertex, proxy). pi-ai merges it, and it takes priority over process env for that provider.

### OAuth / subscription logins and token refresh

- The refresh logic lives in **pi-ai**, not pi-coding-agent. Each provider carries `auth.oauth` with `login`, `refresh(credential, signal)`, `toAuth(credential)` (`auth/types.d.ts`). `Models.getAuth()` calls `refreshStoredOAuthCredential` when the token has under 5 minutes left, **inside `credentials.modify`**, with a 15 s refresh timeout (`resolve.js`).
- So a custom `CredentialStore` whose `modify` takes a lock, passes the current credential to `fn`, and persists the returned credential is all pi-ai needs to refresh `anthropic`, `openai-codex`, `openai` (ChatGPT sign-in), `github-copilot`, `openrouter`, `xai`, `kimi-coding`, `meta`, `radius` subscription logins.
- **Refresh rotates the refresh token.** If nvimpi refreshes and does not persist, pi's copy becomes invalid and the user is logged out of pi. The README says so: "the refresh and its persistence ignore `signal`... a cancelled caller could discard the only valid refresh token". Hence:
  - a writable store must write back atomically (temp file plus rename, or in place as pi does) and preserve all other providers' entries and unknown fields (pi's `modify` does `{...currentData, [provider]: next}` and `JSON.stringify(merged, null, 2)`, mode `0600`);
  - it should use the **same lock** as pi so concurrent pi and nvimpi do not double-refresh. pi uses `proper-lockfile` (a lock directory `auth.json.lock` next to the file, via mkdir). Matching that exactly means depending on `proper-lockfile` (a new dependency, ask first) or reimplementing mkdir-lock semantics. Without it, there is a small race window with a running pi. See open questions.
  - A **read-only store is the safe fallback**: `modify` that throws, as in pi's own `ReadOnlyAuthStorage`. Then a still-valid token works, an expired one fails with `ModelsError("auth")` and the message should tell the user to open pi once to refresh. This avoids ever corrupting pi's file.
- **Bundling caveat for the single esbuild file**: OAuth flow modules are loaded via a variable-specifier dynamic import so bundlers can't follow it (`auth/oauth/load.js`), meaning `refresh`/`toAuth` would fail at runtime in a bundle. pi-ai provides `registerBunOAuthFlows()` from `@earendil-works/pi-ai/bun-oauth` (exported, `package.json` `./bun-oauth`) which statically embeds all flows via `registerBundledOAuthFlowLoaders`. Despite the name it is plain JS. Calling it at sidecar startup should make esbuild include them. **Not tested under esbuild**; needs a spike in the build ticket.

### Experiment (fake credentials only)

Installed `pi-ai@1.4.0` in a scratch dir and ran `createModels` with a 15-line in-memory store holding the auth.json shapes (`anthropic` api_key `FAKE-KEY`, `openai-codex` oauth with a far-future `expires`):

```
file-store anthropic     { source: 'stored credential', hasApiKey: true }
file-store openai-codex  { source: 'OAuth',             hasApiKey: true }
no-store   anthropic     { source: 'ANTHROPIC_API_KEY', hasApiKey: true }   (env var set)
no-store   openai-codex  undefined                                          (no store, no env)
```

This confirms the store contract, the "stored wins over env" rule, and that env resolves with no store. It did not exercise a network refresh (would need a real token).

## 3. What works with no pi installed

| Mechanism | Works without pi? | Notes |
|---|---|---|
| Provider env vars (`ANTHROPIC_API_KEY`, ...) | Yes | Default path, nothing to inject. Must be present in the **Neovim process env** (GUI launchers often lack shell exports); the sidecar inherits Neovim's env. |
| Explicit key (`overrides.apiKey` / `getAuth(..., { apiKey })`) | Yes | Wins over everything. Plain config means the key sits in `init.lua`; discouraged. |
| nvimpi-owned credential store (own JSON file with the same `Credential` shape) | Yes | Same store class pointed at a different path. Needs a way to populate it. |
| Command-based key (`!security find-generic-password ...`) | Only if nvimpi implements `!cmd` resolution | pi-ai doesn't. Alternative: Lua resolves it via `vim.system` and passes the key. |
| Existing OAuth/subscription login from pi | Only if `auth.json` exists | Reuse via the store above. |
| Creating a new OAuth login | Possible in principle | `models.login(provider, 'oauth', interaction)` is public pi-ai API (README), including a callback server and device-code prompts. Large UX surface; out of scope for v1. |

Local/keyless providers (e.g. a local OpenAI-compatible server) need a custom `Provider` via `createProvider`; not covered here.

## 4. Recommended fallback order

Match pi's own documented order (`pi-coding-agent/docs/models.md`: runtime `--api-key`, then `auth.json`, then `models.json`, then env) minus `models.json`, which nvimpi does not read:

1. **Explicit key** from nvimpi `setup()` (opt-in, for people who accept it in config). Passed as `apiKey` override.
2. **pi's `auth.json`** (`$PI_CODING_AGENT_DIR` or `~/.pi/agent`) via a sidecar-owned `CredentialStore`. Covers API keys and subscription OAuth, with refresh by pi-ai.
3. **Provider env vars**, resolved by pi-ai's ambient path (automatic whenever the store has no entry for the provider).

Consequences to state in the architecture issue:

- Because stored credentials own the provider, if `auth.json` has an `anthropic` entry that is broken or expired, nvimpi will **not** fall through to `ANTHROPIC_API_KEY`. This is pi-ai's deliberate behavior and matches pi. Surface the `ModelsError` clearly rather than working around it.
- A missing `auth.json` is not an error: the store returns `undefined` for everything and pi-ai falls to env. Treat a malformed file as a clear error, as pi's `ReadOnlyAuthStorage` does.
- No nvimpi-owned credential file in v1. The "non-pi source" from the map's standing decision is then just env vars plus the optional explicit key.
- Write behavior: start **read-only** (`modify` throws a descriptive error). Add locked write-back only if refresh-failure reports show it's needed, because writing risks corrupting pi's login.

## Open questions for the build

- **Refresh write-back.** Read-only is simplest and safe; but then expired OAuth tokens force the user to run pi to refresh. Does that fit the audience, or do we need a locked write path (needs `proper-lockfile` or a compatible mkdir lock)? Decide after seeing how often tokens are expired in practice.
- **`!cmd` and `$ENV` in `key`.** Replicate pi's `resolveConfigValue` (shell execution, caching, timeout) or support literals and `$ENV` only and report `!cmd` as unsupported?
- **esbuild bundling** of OAuth flows via `registerBunOAuthFlows()` and the lazy provider imports; also bundle size of `builtinModels()` versus registering only the configured provider (`providers/<id>`). Needs a spike.
- **Provider id mapping.** nvimpi's `setup({ provider = ... })` should use pi-ai `Provider.id` strings (same as `auth.json` keys) so no translation layer exists.
- pi-durable is marked **Experimental** ("API changes without notice between releases"); pin the version.

## Sources

All paths are inside the 1.4.0 npm tarballs unless noted.

- `@earendil-works/pi-ai`: `dist/auth/types.d.ts`, `dist/auth/resolve.js`, `dist/auth/credential-store.js`, `dist/auth/helpers.js`, `dist/auth/oauth/load.js`, `dist/bun-oauth.js`, `dist/models.d.ts` (`CreateModelsOptions`), `dist/providers/anthropic.js`, `README.md` (Credential Store, Environment Variables, OAuth), `package.json` `exports`.
- `@earendil-works/pi-durable`: `README.md` (Quick Start: `Harness.open(storage, { models, registry }, context)`; "Built on pi-ai for model access"), `package.json` dependencies.
- `@earendil-works/pi-coding-agent`: `dist/core/auth-storage.js` / `.d.ts`, `dist/core/resolve-config-value.js` / `.d.ts`, `dist/config.js` (`getAgentDir`), `dist/index.d.ts` (exports `readStoredCredential`, `ModelRuntime`), `package.json` `exports`, `CHANGELOG.md` (breaking change removing `AuthStorage` export; `azure` rename), `docs/providers.md` (env table, `!command` keys, `env` object), `docs/models.md` (credential precedence), `docs/configuration.md`.
- Local pi 1.4.0 install at `~/.pi/agent/install/releases/1.4.0` (confirms the packages above are what pi ships) and `~/.pi/agent/auth.json` (structure only: provider ids, `type`, field names, file mode `600`).
