import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import { createModels, envApiKeyAuth, fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import type { FauxProviderHandle, MutableModels, TranscriptContext } from "@earendil-works/pi-ai";
import { handleRequest } from "../src/handler.ts";

const KEY_ENV = "NVIMPI_TEST_FAUX_KEY";

let faux: FauxProviderHandle;
let models: MutableModels;
let seen: TranscriptContext[];

beforeEach(() => {
  faux = fauxProvider({ provider: "faux", models: [{ id: "m1" }] });
  // Same faux model, but its credentials come from an env var like a real provider.
  models = createModels();
  models.setProvider({ ...faux.provider, auth: { apiKey: envApiKeyAuth("Faux", [KEY_ENV]) } });
  process.env[KEY_ENV] = "test-key";
  seen = [];
});

afterEach(() => {
  delete process.env[KEY_ENV];
});

function reply(text: string): void {
  faux.setResponses([
    (context) => {
      seen.push(context);
      return fauxAssistantMessage(text);
    },
  ]);
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

async function respond(line: string): Promise<unknown> {
  const out = await handleRequest(line, models);
  assert.ok(!out.includes("\n"), "response is exactly one line");
  return JSON.parse(out);
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
    const out = (await respond(line)) as { type: string; code: string; message: string };
    assert.equal(out.type, "error");
    assert.equal(out.code, "invalid_request");
    assert.ok(out.message.length > 0);
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
  const out = (await respond(request())) as { type: string; code: string; message: string };
  assert.equal(out.type, "error");
  assert.equal(out.code, "provider");
  assert.match(out.message, /rate limited/);
});
