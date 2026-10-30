import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { createModels, envApiKeyAuth, fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import type { CredentialStore, FauxProviderHandle, MutableModels, OAuthAuth, TranscriptContext } from "@earendil-works/pi-ai";
import { handleRequest } from "../src/handler.ts";
import { createSecrets } from "../src/secrets.ts";

const KEY_ENV = "NVIMPI_TEST_FAUX_KEY";

let faux: FauxProviderHandle;
let seen: TranscriptContext[];
let seenKeys: (string | undefined)[];
let refreshCalls: number;
let agentDir: string;

beforeEach(() => {
  faux = fauxProvider({ provider: "faux", models: [{ id: "m1" }] });
  process.env[KEY_ENV] = "test-key";
  seen = [];
  seenKeys = [];
  refreshCalls = 0;
  agentDir = mkdtempSync(join(tmpdir(), "nvimpi-agent-"));
  process.env.PI_CODING_AGENT_DIR = agentDir;
});

afterEach(() => {
  delete process.env[KEY_ENV];
  delete process.env.NVIMPI_TEST_REF;
  delete process.env.PI_CODING_AGENT_DIR;
  rmSync(agentDir, { recursive: true, force: true });
});

// A subscription login for the faux provider. Refresh must never run: nvimpi is read-only.
const fauxOAuth: OAuthAuth = {
  name: "Faux login",
  login: async () => {
    throw new Error("login is not used");
  },
  refresh: async (credential) => {
    refreshCalls += 1;
    return { ...credential, expires: Date.now() + 3_600_000 };
  },
  toAuth: async (credential) => ({ apiKey: `oauth:${String(credential.access)}` }),
};

/** The same faux model, with credentials resolved like a real provider (env var or OAuth). */
function makeModels(credentials: CredentialStore): MutableModels {
  const models = createModels({ credentials });
  models.setProvider({ ...faux.provider, auth: { apiKey: envApiKeyAuth("Faux", [KEY_ENV]), oauth: fauxOAuth } });
  return models;
}

function reply(text: string): void {
  faux.setResponses([
    (context, options) => {
      seen.push(context);
      seenKeys.push(options?.apiKey);
      return fauxAssistantMessage(text);
    },
  ]);
}

function writeAuth(content: unknown): string {
  const path = join(agentDir, "auth.json");
  writeFileSync(path, typeof content === "string" ? content : JSON.stringify(content, null, 2));
  return path;
}

function request(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    mode: "rewrite",
    instruction: "make it shout",
    before: "local a = 1\n",
    selection: "print('hi')",
    after: "\nlocal b = 2\n",
    filetype: "lua",
    model: { provider: "faux", id: "m1" },
    ...overrides,
  });
}

type Out = { type: string; code?: string; message?: string; text?: string };

async function respond(line: string): Promise<Out> {
  const out = await handleRequest(line, makeModels);
  assert.ok(!out.includes("\n"), "response is exactly one line");
  return JSON.parse(out) as Out;
}

function systemText(context: TranscriptContext): string {
  return JSON.stringify(context.messages.filter((m) => m.role === "system"));
}

function userText(context: TranscriptContext): string {
  return JSON.stringify(context.messages.filter((m) => m.role === "user"));
}

test("rewrite returns the model's reply as the result", async () => {
  reply("PRINT('HI')");
  assert.deepEqual(await respond(request()), { type: "result", text: "PRINT('HI')" });
});

test("rewrite sends a raw rewrite system prompt and the instruction, Context and selection", async () => {
  reply("x");
  await respond(request());
  const system = systemText(seen[0]!);
  assert.match(system, /only the replacement text/);
  assert.match(system, /lua/);
  assert.doesNotMatch(system, /<instructions>/);
  const user = userText(seen[0]!);
  for (const part of ["make it shout", "local a = 1", "print('hi')", "local b = 2"]) {
    assert.ok(user.includes(part), `user message contains ${part}`);
  }
});

test("a whole-line selection asks for no trailing newline", async () => {
  reply("x");
  await respond(request({ before: "a\n", selection: "b\nc", after: "\nd\n" }));
  assert.match(systemText(seen[0]!), /trailing newline/);
});

test("a partial-line selection does not mention the trailing newline", async () => {
  reply("x");
  await respond(request({ before: "a\nfoo(", selection: "b", after: ")\n" }));
  assert.doesNotMatch(systemText(seen[0]!), /trailing newline/);
});

function insertRequest(overrides: Record<string, unknown> = {}): string {
  return request({ mode: "insert", instruction: "add a log", before: "foo(", selection: "", after: "bar)\n", ...overrides });
}

test("insert sends an Insert system prompt and marks the cursor between before and after", async () => {
  reply("x");
  await respond(insertRequest());
  const system = systemText(seen[0]!);
  assert.match(system, /<cursor\/>/);
  assert.match(system, /only the text to insert/);
  assert.match(system, /lua/);
  assert.doesNotMatch(system, /<selection>|replacement text|trailing newline/);
  const user = userText(seen[0]!);
  assert.ok(user.includes("add a log"), "user message contains the instruction");
  assert.ok(user.includes("foo(<cursor/>bar)"), "the cursor marker sits between before and after");
  assert.doesNotMatch(user, /<selection>/);
});

test("insert returns the model's reply, fence stripped", async () => {
  reply("```lua\nlog(1)\nlog(2)\n```");
  assert.deepEqual(await respond(insertRequest()), { type: "result", text: "log(1)\nlog(2)" });
});

test("insert drops one trailing newline from the reply", async () => {
  reply("log(1)\n");
  assert.deepEqual(await respond(insertRequest({ before: "a\n", after: "\nb\n" })), { type: "result", text: "log(1)" });
});

test("strips a code fence around the whole reply", async () => {
  reply("```lua\nprint('HI')\nprint('YO')\n```");
  assert.deepEqual(await respond(request()), { type: "result", text: "print('HI')\nprint('YO')" });
});

test("strips a bare code fence with surrounding whitespace", async () => {
  reply("\n```\nx = 1\n```\n");
  assert.deepEqual(await respond(request()), { type: "result", text: "x = 1" });
});

test("keeps fences that are part of the text", async () => {
  const text = "Example:\n```lua\nx = 1\n```\nDone.";
  reply(text);
  assert.deepEqual(await respond(request()), { type: "result", text });
});

test("drops one trailing newline the selection did not have", async () => {
  reply("b2\nc2\n");
  assert.deepEqual(await respond(request({ before: "a\n", selection: "b\nc", after: "\nd\n" })), {
    type: "result",
    text: "b2\nc2",
  });
});

test("an empty reply is an empty result", async () => {
  reply("");
  assert.deepEqual(await respond(request()), { type: "result", text: "" });
});

for (const [name, line] of [
  ["not JSON", "{nope"],
  ["not an object", "[1,2]"],
  ["unknown mode", request({ mode: "explain" })],
  ["missing instruction", request({ instruction: undefined })],
  ["non-string selection", request({ selection: 3 })],
  ["missing model", request({ model: undefined })],
  ["model without id", request({ model: { provider: "faux" } })],
  ["empty provider", request({ model: { provider: "", id: "m1" } })],
] as const) {
  test(`invalid_request: ${name}`, async () => {
    const out = await respond(line);
    assert.equal(out.type, "error");
    assert.equal(out.code, "invalid_request");
    assert.ok((out.message ?? "").length > 0);
  });
}

test("not_configured for an unknown model", async () => {
  assert.deepEqual(await respond(request({ model: { provider: "faux", id: "nope" } })), {
    type: "error",
    code: "not_configured",
    message: "unknown model faux/nope: run :NvimpiModel",
  });
});

test("not_configured for an unknown provider", async () => {
  assert.deepEqual(await respond(request({ model: { provider: "nobody", id: "m1" } })), {
    type: "error",
    code: "not_configured",
    message: "unknown model nobody/m1: run :NvimpiModel",
  });
});

test("not_configured when the provider has no credentials", async () => {
  delete process.env[KEY_ENV];
  assert.deepEqual(await respond(request()), {
    type: "error",
    code: "not_configured",
    message: "no credentials for faux: log in with pi, or set its API key env var",
  });
});

test("a provider failure is a provider error carrying its message", async () => {
  faux.setResponses([fauxAssistantMessage("", { stopReason: "error", errorMessage: "rate limited" })]);
  const out = await respond(request());
  assert.equal(out.type, "error");
  assert.equal(out.code, "provider");
  assert.match(out.message ?? "", /rate limited/);
});

// --- Credentials: pi's auth.json, then provider env vars ---

test("an auth.json literal key wins over the provider env var", async () => {
  writeAuth({ faux: { type: "api_key", key: "from-file" } });
  reply("ok");
  assert.deepEqual(await respond(request()), { type: "result", text: "ok" });
  assert.deepEqual(seenKeys, ["from-file"]);
});

test("an auth.json $ENV key reads that env var", async () => {
  process.env.NVIMPI_TEST_REF = "via-env";
  writeAuth({ faux: { type: "api_key", key: "$NVIMPI_TEST_REF" } });
  reply("ok");
  assert.equal((await respond(request())).type, "result");
  assert.deepEqual(seenKeys, ["via-env"]);
});

test("an auth.json ${ENV} key interpolates that env var", async () => {
  process.env.NVIMPI_TEST_REF = "via-env";
  writeAuth({ faux: { type: "api_key", key: "pre-${NVIMPI_TEST_REF}-post" } });
  reply("ok");
  assert.equal((await respond(request())).type, "result");
  assert.deepEqual(seenKeys, ["pre-via-env-post"]);
});

test("$$ and $! in an auth.json key are a literal $ and !", async () => {
  writeAuth({ faux: { type: "api_key", key: "a$$b$!c" } });
  reply("ok");
  assert.equal((await respond(request())).type, "result");
  assert.deepEqual(seenKeys, ["a$b!c"]);
});

test("an auth.json !command key uses the command's trimmed stdout", async () => {
  writeAuth({ faux: { type: "api_key", key: "!printf '  from-cmd\\n'" } });
  reply("ok");
  assert.equal((await respond(request())).type, "result");
  assert.deepEqual(seenKeys, ["from-cmd"]);
});

test("an auth.json !command runs once per request", async () => {
  const counter = join(agentDir, "runs");
  writeAuth({ faux: { type: "api_key", key: `!echo x >> '${counter}'; echo key` } });
  reply("ok");
  assert.equal((await respond(request())).type, "result");
  assert.equal(readFileSync(counter, "utf8"), "x\n");
});

test("an auth.json !command that times out is a provider error after 5 s", async () => {
  const path = writeAuth({ faux: { type: "api_key", key: "!sleep 30; echo late" } });
  reply("ok");
  const started = Date.now();
  const out = await respond(request());
  const elapsed = Date.now() - started;
  assert.deepEqual(out, {
    type: "error",
    code: "provider",
    message: `faux key command in ${path} timed out after 5 s: sleep 30; echo late`,
  });
  assert.ok(elapsed >= 4_900 && elapsed < 9_000, `took ${elapsed} ms`);
  assert.equal(seen.length, 0);
});

test("a failing auth.json !command is a provider error, not a fall through to the env var", async () => {
  const path = writeAuth({ faux: { type: "api_key", key: "!exit 3" } });
  reply("ok");
  assert.deepEqual(await respond(request()), {
    type: "error",
    code: "provider",
    message: `faux key command in ${path} failed (exit 3): exit 3`,
  });
  assert.equal(seen.length, 0);
});

test("an auth.json !command that prints nothing is a provider error", async () => {
  const path = writeAuth({ faux: { type: "api_key", key: "!true" } });
  assert.deepEqual(await respond(request()), {
    type: "error",
    code: "provider",
    message: `faux key command in ${path} printed nothing: true`,
  });
});

test("an auth.json key naming an unset env var does not fall through to the provider env var", async () => {
  const path = writeAuth({ faux: { type: "api_key", key: "$NVIMPI_TEST_REF" } });
  reply("ok");
  assert.deepEqual(await respond(request()), {
    type: "error",
    code: "provider",
    message: `faux key in ${path} uses $NVIMPI_TEST_REF, which is not set`,
  });
  assert.equal(seen.length, 0);
});

test("an auth.json entry of an unknown shape is a provider error naming the path", async () => {
  const path = writeAuth({ faux: { type: "api_key", key: 42 } });
  assert.deepEqual(await respond(request()), {
    type: "error",
    code: "provider",
    message: `invalid faux entry in ${path}`,
  });
});

test("a valid OAuth login from auth.json is used", async () => {
  writeAuth({ faux: { type: "oauth", access: "tok", refresh: "r", expires: Date.now() + 3_600_000 } });
  reply("ok");
  assert.equal((await respond(request())).type, "result");
  assert.deepEqual(seenKeys, ["oauth:tok"]);
});

test("an expired OAuth login asks the user to open pi, and never refreshes or writes auth.json", async () => {
  const path = writeAuth({ faux: { type: "oauth", access: "tok", refresh: "r", expires: Date.now() - 1_000, accountId: "x" } });
  const before = readFileSync(path, "utf8");
  const mtime = statSync(path).mtimeMs;
  reply("ok");
  assert.deepEqual(await respond(request()), {
    type: "error",
    code: "provider",
    message: `faux login in ${path} has expired: open pi to refresh your faux login`,
  });
  assert.equal(refreshCalls, 0);
  assert.equal(readFileSync(path, "utf8"), before);
  assert.equal(statSync(path).mtimeMs, mtime);
  assert.equal(seen.length, 0);
});

test("a malformed auth.json is a provider error naming the path", async () => {
  const path = writeAuth("{ not json");
  const out = await respond(request());
  assert.equal(out.code, "provider");
  assert.ok(out.message?.startsWith(`cannot read pi credentials from ${path}: `), out.message);
});

test("an auth.json that is not an object is a provider error naming the path", async () => {
  const path = writeAuth("[]");
  assert.deepEqual(await respond(request()), {
    type: "error",
    code: "provider",
    message: `cannot read pi credentials from ${path}: expected a JSON object`,
  });
});

test("a missing auth.json falls through to the provider env var", async () => {
  reply("ok");
  assert.equal((await respond(request())).type, "result");
  assert.deepEqual(seenKeys, ["test-key"]);
});

test("an auth.json without an entry for the provider falls through to the env var", async () => {
  writeAuth({ other: { type: "api_key", key: "nope" } });
  reply("ok");
  assert.equal((await respond(request())).type, "result");
  assert.deepEqual(seenKeys, ["test-key"]);
});

test("auth.json defaults to ~/.pi/agent, and PI_CODING_AGENT_DIR expands ~", async () => {
  const home = process.env.HOME;
  process.env.HOME = agentDir;
  try {
    delete process.env.PI_CODING_AGENT_DIR;
    mkdirSync(join(agentDir, ".pi", "agent"), { recursive: true });
    writeFileSync(join(agentDir, ".pi", "agent", "auth.json"), JSON.stringify({ faux: { type: "api_key", key: "default-dir" } }));
    reply("ok");
    await respond(request());

    process.env.PI_CODING_AGENT_DIR = "~/custom";
    mkdirSync(join(agentDir, "custom"));
    writeFileSync(join(agentDir, "custom", "auth.json"), JSON.stringify({ faux: { type: "api_key", key: "custom-dir" } }));
    reply("ok");
    await respond(request());
    assert.deepEqual(seenKeys, ["default-dir", "custom-dir"]);
  } finally {
    process.env.HOME = home;
  }
});

// --- Setup key: the request's api_key, before auth.json and env vars ---

test("a setup api_key wins over auth.json and the provider env var", async () => {
  writeAuth({ faux: { type: "api_key", key: "from-file" } });
  reply("ok");
  assert.deepEqual(await respond(request({ api_key: "fake-setup-key" })), { type: "result", text: "ok" });
  assert.deepEqual(seenKeys, ["fake-setup-key"]);
});

test("a setup api_key owns the provider: a broken auth.json entry is never read", async () => {
  writeAuth({ faux: { type: "api_key", key: "!exit 1" } });
  reply("ok");
  assert.deepEqual(await respond(request({ api_key: "fake-setup-key" })), { type: "result", text: "ok" });
  assert.deepEqual(seenKeys, ["fake-setup-key"]);
});

test("a rejected setup api_key is a provider error with the key redacted, not a fall through", async () => {
  writeAuth({ faux: { type: "api_key", key: "from-file" } });
  faux.setResponses([
    (_context, options) => {
      seenKeys.push(options?.apiKey);
      return fauxAssistantMessage("", { stopReason: "error", errorMessage: `invalid key ${options?.apiKey} (${options?.apiKey})` });
    },
  ]);
  const out = await respond(request({ api_key: "fake-setup-key" }));
  assert.equal(out.code, "provider");
  assert.equal(out.message, "faux/m1: invalid key *** (***)");
  assert.deepEqual(seenKeys, ["fake-setup-key"]);
});

for (const [name, apiKey] of [
  ["non-string api_key", 42],
  ["empty api_key", ""],
] as const) {
  test(`invalid_request: ${name}`, async () => {
    const out = await respond(request({ api_key: apiKey }));
    assert.equal(out.code, "invalid_request");
    assert.equal(out.message, "invalid request: api_key must be a non-empty string");
  });
}

// --- Redaction: every credential resolved for the request is *** in every message ---

/** The model rejects whatever key it was given, echoing it in the error. */
function rejectEchoingKey(): void {
  faux.setResponses([
    (_context, options) => fauxAssistantMessage("", { stopReason: "error", errorMessage: `invalid key ${options?.apiKey}` }),
  ]);
}

const REJECTED = { type: "error", code: "provider", message: "faux/m1: invalid key ***" };

for (const [name, entry] of [
  ["an auth.json literal key", { type: "api_key", key: "file-secret" }],
  ["an auth.json $ENV key", { type: "api_key", key: "$NVIMPI_TEST_REF" }],
  ["an auth.json !command key", { type: "api_key", key: "!echo cmd-secret" }],
  ["an auth.json OAuth token", { type: "oauth", access: "tok-secret", refresh: "r", expires: Date.now() + 3_600_000 }],
] as const) {
  test(`${name} echoed in a provider error is redacted`, async () => {
    process.env.NVIMPI_TEST_REF = "env-ref-secret";
    writeAuth({ faux: entry });
    rejectEchoingKey();
    assert.deepEqual(await respond(request()), REJECTED);
  });
}

test("a provider env var key echoed in a provider error is redacted", async () => {
  rejectEchoingKey();
  assert.deepEqual(await respond(request()), REJECTED);
});

test("the caller's secrets learn every credential resolved, to redact stderr too", async () => {
  writeAuth({ faux: { type: "api_key", key: "!echo cmd-secret" } });
  reply("ok");
  const secrets = createSecrets();
  await handleRequest(request(), makeModels, secrets);
  assert.equal(secrets.redact("Error: cmd-secret rejected"), "Error: *** rejected");
});
