// Runs the committed bundle as Lua does: a separate process, from a directory with no node_modules.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

const BUNDLE = new URL("../dist/sidecar.mjs", import.meta.url).pathname;
const FETCH_STUB = new URL("./fetch-stub.mjs", import.meta.url).pathname;
let dir: string;

before(() => {
  dir = mkdtempSync(join(tmpdir(), "nvimpi-smoke-"));
  copyFileSync(BUNDLE, join(dir, "sidecar.mjs"));
  copyFileSync(FETCH_STUB, join(dir, "fetch-stub.mjs"));
});

after(() => rmSync(dir, { recursive: true, force: true }));

function run(stdin: string, env: Record<string, string> = {}, args: string[] = []): unknown {
  // No provider env vars, HOME points at the empty dir, and fetch never reaches the network.
  const result = spawnSync(process.execPath, ["--import", "./fetch-stub.mjs", "sidecar.mjs", ...args], {
    cwd: dir,
    input: stdin,
    env: { PATH: process.env.PATH, HOME: dir, ...env },
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.equal(result.status, 0, result.stderr);
  const lines = result.stdout.split("\n");
  assert.equal(lines.length, 2, `exactly one stdout line, got: ${result.stdout}`);
  assert.equal(lines[1], "");
  return JSON.parse(lines[0]!);
}

function request(model: { provider: string; id: string }): string {
  return `${JSON.stringify({ mode: "rewrite", instruction: "x", before: "", selection: "y", after: "", filetype: "", model })}\n`;
}

test("malformed stdin gives invalid_request", () => {
  const out = run("this is not json\n") as { type: string; code: string };
  assert.equal(out.type, "error");
  assert.equal(out.code, "invalid_request");
});

test("an unknown model gives not_configured", () => {
  assert.deepEqual(run(request({ provider: "anthropic", id: "no-such-model" })), {
    type: "error",
    code: "not_configured",
    message: "unknown model anthropic/no-such-model: run :NvimpiModel",
  });
});

test("a bundled provider without credentials gives not_configured", () => {
  const id = "claude-sonnet-4-5";
  assert.deepEqual(run(request({ provider: "anthropic", id })), {
    type: "error",
    code: "not_configured",
    message: "no credentials for anthropic: log in with pi, or set its API key env var",
  });
});

/** Writes an auth.json into a fresh agent dir and returns the env pointing at it. */
function agentDir(name: string, auth: unknown): Record<string, string> {
  const path = join(dir, name);
  mkdirSync(path);
  writeFileSync(join(path, "auth.json"), JSON.stringify(auth));
  return { PI_CODING_AGENT_DIR: path };
}

const SONNET = { provider: "anthropic", id: "claude-sonnet-4-5" };

test("an auth.json API key is sent, and wins over the provider env var", () => {
  const env = agentDir("api-key", { anthropic: { type: "api_key", key: "file-key" } });
  const out = run(request(SONNET), { ...env, ANTHROPIC_API_KEY: "env-key" }) as { code: string; message: string };
  assert.equal(out.code, "provider");
  assert.match(out.message, /fetch-stub saw file-key/);
});

test("a setup api_key is sent over auth.json and the env var, and redacted from the error", () => {
  const env = agentDir("setup-key", { anthropic: { type: "api_key", key: "file-key" } });
  const line = `${JSON.stringify({ ...JSON.parse(request(SONNET)), api_key: "fake-setup-key" })}\n`;
  const out = run(line, { ...env, ANTHROPIC_API_KEY: "env-key" }) as { code: string; message: string };
  assert.equal(out.code, "provider");
  assert.match(out.message, /fetch-stub saw \*\*\*/);
  assert.doesNotMatch(out.message, /fake-setup-key/);
});

// The OAuth bundle spike: pi-ai loads OAuth flows through an import esbuild cannot follow,
// so toAuth only works in the bundle because main registers them with registerBunOAuthFlows().
test("a valid pi OAuth login works inside the bundle", () => {
  const login = { type: "oauth", access: "oauth-access", refresh: "r", expires: Date.now() + 3_600_000 };
  const out = run(request(SONNET), agentDir("oauth", { anthropic: login })) as { code: string; message: string };
  assert.equal(out.code, "provider");
  assert.match(out.message, /fetch-stub saw oauth-access/);
});

test("an expired pi OAuth login asks the user to open pi", () => {
  const env = agentDir("expired", { anthropic: { type: "oauth", access: "a", refresh: "r", expires: 1 } });
  assert.deepEqual(run(request(SONNET), env), {
    type: "error",
    code: "provider",
    message: `anthropic login in ${join(env.PI_CODING_AGENT_DIR!, "auth.json")} has expired: open pi to refresh your anthropic login`,
  });
});

test("--list-models with no credentials prints an empty JSON array", () => {
  assert.deepEqual(run("", {}, ["--list-models"]), []);
});

test("--credential-source names what covers one provider", () => {
  const env = agentDir("source", { openai: { type: "api_key", key: "!exit 1" } });
  assert.deepEqual(run("", env, ["--credential-source", "openai"]), { type: "source", source: "auth.json" });
  assert.deepEqual(run("", { ANTHROPIC_API_KEY: "k" }, ["--credential-source", "anthropic"]), { type: "source", source: "env" });
  assert.deepEqual(run("", {}, ["--credential-source", "anthropic"]), { type: "source", source: "none" });
});

test("--list-models lists providers with an env var or auth.json entry, plus the ids passed in", () => {
  const env = agentDir("list", { openai: { type: "api_key", key: "!exit 1" } });
  const listed = run("", { ...env, ANTHROPIC_API_KEY: "env-key" }, ["--list-models", "mistral"]) as string[];
  assert.ok(listed.includes("anthropic/claude-sonnet-4-5"), "env var provider");
  const providers = new Set(listed.map((model) => model.slice(0, model.indexOf("/"))));
  assert.deepEqual([...providers].sort(), ["anthropic", "mistral", "openai"]);
});
