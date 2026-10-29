# pi-durable one-shot API and ephemeral storage

Resolves issue #2 (parent map: #1). Blocks #6.

## Answer

- **Minimal call:** one `Harness` over `MemoryStorage`, one root conversation configured with `model` and `instructions`, one `submit({ type: "input", content })`, then `wait()`. The final text is the `AssistantEntry` that `settled.answer` points to. No tools, no extensions, no filesystem environment are needed.
- **Abort:** `await conversation.abort(context)` while the submission is in flight. The run's `AbortSignal` goes into the provider request, and the submission settles `{ status: "unanswered", reason: "aborted" }`. `Submission.abort()` is not this: it only withdraws a still-queued input.
- **Ephemeral storage:** yes. `MemoryStorage` ("Nothing is persisted") is exported from the package root. A run with it left the working directory unchanged (verified, see "Verification").
- **Version:** `@earendil-works/pi-durable@1.4.0`, labelled **experimental** ("The API changes without notice between releases"). Pin the exact version.

## Sources and versions

Read from the npm tarballs, unpacked into a scratch dir outside the repo (`npm pack`, no scripts run):

| Package | Version | Files read |
|---|---|---|
| `@earendil-works/pi-durable` | 1.4.0 | `README.md`, `package.json`, `dist/index.d.ts`, `dist/harness/{types,agent,prompt,generation}.*`, `dist/entries.d.ts`, `dist/types.d.ts` |
| `@earendil-works/pi-ai` | 1.4.0 | `README.md`, `package.json`, `dist/providers/faux.d.ts`, `dist/auth/{types,credential-store}.d.ts`, `dist/utils/transcript.js` |
| `@earendil-works/chord` | 1.4.0 | `dist/context/index.d.ts` (the `Context` type) |

The source repo is `github.com/earendil-works/pi`, `packages/durable` (from `package.json` `repository`). I did not read the GitHub tree or `docs/spec.md` (the README's normative spec); the npm `dist` is the code that would ship. Package `engines`: `node >=22.19.0`, so Node 24 is fine.

## Minimal call

Install: `@earendil-works/pi-durable @earendil-works/pi-ai @earendil-works/chord` (the README's install line; the last two are needed for imports).

```ts
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { AssistantEntry, createRegistry, defineExtension, Harness, MemoryStorage, section } from "@earendil-works/pi-durable";

// Raw system prompt. `agent.instructions` also works but is wrapped as <instructions>…</instructions>.
const systemPrompt = (text: string) =>
	defineExtension({ name: "nvimpi", sections: [section("system", () => text, { tag: false })] });

async function rewrite(provider: string, modelId: string, system: string, user: string, signal: AbortSignal): Promise<string> {
	const models = createModels();
	models.setProvider(anthropicProvider()); // one provider per request; see "Provider registration"
	const registry = createRegistry();
	registry.install(systemPrompt(system)); // no tools installed, so the model cannot call any

	const harness = await Harness.open(
		new MemoryStorage(),
		{ models, registry, settings: { retry: { enabled: false }, compaction: { enabled: false } } },
		BACKGROUND_CONTEXT,
	);
	try {
		const conversation = await harness.root(BACKGROUND_CONTEXT, { agent: { model: { provider, modelId } } });
		const submission = await conversation.submit({ type: "input", content: user }, BACKGROUND_CONTEXT);
		signal.addEventListener("abort", () => void conversation.abort(BACKGROUND_CONTEXT), { once: true });

		const settled = await submission.wait(BACKGROUND_CONTEXT);
		if (settled.status !== "done" || settled.type !== "input") {
			throw new Error(`pi-durable: ${settled.reason}${settled.detail ? `: ${JSON.stringify(settled.detail)}` : ""}`);
		}
		const answer = await conversation.commit((tx) => tx.entry(AssistantEntry, settled.answer), BACKGROUND_CONTEXT);
		const message = answer?.model?.[0]; // pi-ai AssistantMessage
		if (message?.role !== "assistant") throw new Error("pi-durable: no assistant message");
		return message.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
	} finally {
		await harness.close(BACKGROUND_CONTEXT);
	}
}
```

Notes on the sketch:

- **Typed surface used:** `Harness.open(storage, options, context)`, `harness.root(context, { agent })`, `conversation.submit(draft, context)`, `submission.wait(context)`, `conversation.commit(fn, context)`, `harness.close(context)`. All are in `dist/harness/types.d.ts` (`Harness`, `Conversation`, `Submission`).
- **Explicit provider and model:** `agent.model` is `ModelRef = { provider: string; modelId: string }`, resolved through pi-ai `Models`. If the provider is not registered, the run settles `unanswered` with `reason: "no_model"` (`generation.js`: `failNoModel`).
- **No default model.** Without `agent.model` the run also fails with `no_model`, which fits the standing "no default model" decision.
- **Every async call takes a Chord `Context`.** `BACKGROUND_CONTEXT` never cancels. `Context` carries `abortSignal` and telemetry (`chord/dist/context/index.d.ts`).
- **Reading the text:** `settled.answer` is an `EntryId`, not text. Reading it takes one more call, `conversation.commit((tx) => tx.entry(AssistantEntry, id))` (the README quick start does the same). `AssistantEntry.model[0]` is a pi-ai `AssistantMessage` whose `content` is blocks (`text`, `thinking`, `toolCall`).
- **Settlement shape:** `SubmissionRecord` (`dist/types.d.ts`). `status: "done"` carries `entry` and `answer`; `status: "unanswered"` carries `reason: string` and optional `detail`.

### System prompt

Two ways, both verified by capturing the request in the faux provider:

| Way | What the model sees |
|---|---|
| `agent.instructions: "Return only the replacement text."` | A system message with `sections: { instructions: "<instructions>\nReturn only the replacement text.\n</instructions>" }`. `harness/prompt.js` `renderSections` wraps every section as `<key>\n…\n</key>` unless `tag: false`. |
| An extension with `section("system", () => text, { tag: false })` | `sections: { system: "<text verbatim>" }`. |

pi-ai replays system messages into one system prompt (`pi-ai/dist/utils/transcript.js` `getCurrentSystemMessage`: `content` joined, `sections` patched by name). I did not trace how each provider concatenates `sections` into its wire format; the faux provider only shows the transcript. The tag wrapper is harmless for most models, but the untagged section gives the sidecar full control of the prompt text. There is no separate "base system prompt" injected by pi-durable in this configuration: the empty-registry request contained only the section message and the user message.

### Settings that matter for a one-shot

Defaults from `harness/agent.js`:

- `retry`: `{ enabled: true, maxRetries: 3, baseDelayMs: 2000, maxAgentDelayMs: 60000 }`. A model error would otherwise sleep and retry for up to a minute, which is wrong for an interactive editor action. The sketch sets `retry: { enabled: false }`. `settings.stream.maxRetries` is a separate provider/SDK-level retry inside one attempt (`ConversationStreamOptions`).
- `compaction`: enabled by default. Irrelevant for one message, so the sketch disables it.
- `settings.stream.timeoutMs` exists (`ConversationStreamOptions`). I did not verify its default. The sidecar should enforce its own overall timeout by calling the same abort path.
- `thinkingLevel` is an `AgentChange` field; the request omits `reasoning` when it is `"off"` (`generation.js`). The default was not checked.

## Abort

- **In flight:** `await conversation.abort(context)` (`Conversation.abort`: "withdraw queued inputs, mark every live non-background task of the ordinary ownership scope, signal them, and resolve once the scope is idle"). The generation task passes `runtime.signal` as the provider request's `signal` (`generation.js`), and pi-ai documents that aborted requests end with `stopReason === 'aborted'` (`pi-ai/README.md`, "Aborting Requests"). The submission then settles `unanswered` / `aborted`.
- **Verified:** with a slow faux provider (5 tokens/s), calling `conversation.abort()` 50 ms in settled the submission as `{"status":"unanswered","reason":"aborted"}` and the process exited cleanly after `harness.close()`.
- **Not the cancel path:**
  - `Submission.abort()` returns `"aborted" | "already_placed" | "settled"`. Once the input is placed in a run it returns `already_placed`, so it only withdraws queued inputs.
  - Cancelling the `Context` you pass to `wait()` cancels only that wait, not the work (README: "Cancelling a wait only cancels that wait, never the work"). I read this but did not test it.
- **Mapping for the sidecar:** a Lua `cancel` message maps to `conversation.abort()` for that request's conversation. Report the result as cancelled when `reason === "aborted"`.
- Other `unanswered` reasons seen in the source: `model_error` (with `detail` text), `no_model`, `faulted`, `stale`, `reset`. The sidecar should surface `model_error` detail as the user-facing error.

## Ephemeral storage

- `MemoryStorage` (package root export). The README's storage table: "Nothing is persisted." SQLite (`openNodeSqliteStorage(file)`) and JSONL (`openNodeJsonlStorage(directory)`) are separate subpath imports that the sidecar never needs, so nothing writes to disk and no temp dir is required.
- **Verified:** after a full run plus an aborted run, `readdirSync(cwd)` was identical before and after. (This checks the working directory only, not `$TMPDIR` or `~/.pi`. Nothing in the call path configures a file location, and no `env` is passed, so I expect no writes. A stricter check would be `strace`/`fs_usage`.)
- The Harness is built per request in the sketch, so state lives only for that request. A single long-lived Harness with `createConversation({ ownership: { kind: "ownerless" } })` per request would also work, but I found no conversation-delete API and `MemoryStorage` would keep growing, so per-request is simpler. I only tested the per-request form.
- **Experimental caveat on `resume()`:** not called, and not needed. Submitting or waiting starts the scheduler (README, "Persist and Resume").

## Provider registration and credentials (feeds the model and credential tickets)

- `createModels()` + `models.setProvider(xProvider())` where each provider is a subpath import (`@earendil-works/pi-ai/providers/<name>`). `builtinModels()` from `providers/all` registers everything but is "the heavy, explicit entrypoint" (pi-ai README).
- The user picks `provider` as a string at runtime, so the sidecar needs a table from provider id to factory. With the bundling decision (one committed JS file, esbuild), this is a real tradeoff: static imports of all provider factories vs. `builtinModels()`. Provider factories lazy-load their SDKs ("SDK implementations stay in lazy chunks" with code splitting), which a single-file bundle may not preserve. Bundle size and whether esbuild copes with these packages were **not tested**.
- **Auth:** `models.complete/stream` resolves auth through the provider: stored credential, then environment variable (for example `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`; table in the pi-ai README, "Environment Variables"). "A stored credential owns its provider: environment variables are only consulted when nothing is stored."
- `createModels({ credentials })` takes a `CredentialStore` (`read`, `list`, `modify`, `delete`). Its `Credential` type is documented as "the shape of today's auth.json" (`pi-ai/dist/auth/types.d.ts`), with `{ type: "api_key", key }` for API keys. pi-ai exports only `InMemoryCredentialStore`; its own file-backed store lives in `cli.js` (`AUTH_FILE = "auth.json"`) and is not exported. So reading `~/.pi/agent/auth.json` means writing a small read-only `CredentialStore` in the sidecar (OAuth entries need `modify` for refresh, which is a further complication for the credentials ticket).
- `ConversationStreamOptions` (what `settings.stream` accepts) has no `apiKey`. A per-request explicit key therefore goes through a `CredentialStore` or the environment, not through pi-durable's stream options.

## Cost and risks

- **Surface is large for a one-shot.** The package is a durable agent harness (tasks, documents, scheduler, tools, code mode). The one-shot path uses a small slice, but dependencies are heavy: `package.json` lists `@earendil-works/{chord,pi-ai,pi-codemode,pi-telemetry}`, `@silvia-odwyer/photon`, `diff`, `typebox`. The README says the package root loads TypeBox, "about 4 MB in a tree-shaken bundle" of peak RSS (23 MB unbundled).
- **Experimental:** API "changes without notice between releases". Pin `1.4.0` and treat upgrades as deliberate. The committed bundle makes this natural.
- **Extra round trip to read text:** unavoidable with this API (the answer is an entry ID).
- **Streaming exists** (README: the 16-real-model example streams) but is out of scope per the standing decision (final text only).

## Verification

Done in a scratch dir outside the repo: `npm i --ignore-scripts` of the three packages at 1.4.0 plus `typescript`, then:

- `tsc --strict` (NodeNext) type-checked the sketch exactly as written above (including the `anthropicProvider` import; it was not executed).
- Run against pi-ai's `fauxProvider` (no network): the normal run settled `done` and returned the scripted text; the 50 ms abort settled `unanswered`/`aborted`; the tagged and untagged system prompts appeared in the captured request as described above.
- **Not run:** any real provider call, esbuild bundling, and the sketch itself (the runtime probes used the same calls with `fauxProvider`).
