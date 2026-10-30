import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { createModels, envApiKeyAuth, fauxProvider } from "@earendil-works/pi-ai";
import type { CredentialStore, MutableModels } from "@earendil-works/pi-ai";
import { listModels } from "../src/list-models.ts";

const FAUX_ENV = "NVIMPI_TEST_FAUX_KEY";
const OTHER_ENV = "NVIMPI_TEST_OTHER_KEY";

let agentDir: string;

beforeEach(() => {
  agentDir = mkdtempSync(join(tmpdir(), "nvimpi-list-"));
  process.env.PI_CODING_AGENT_DIR = agentDir;
  delete process.env[FAUX_ENV];
  delete process.env[OTHER_ENV];
});

afterEach(() => {
  delete process.env.PI_CODING_AGENT_DIR;
  delete process.env[FAUX_ENV];
  delete process.env[OTHER_ENV];
  rmSync(agentDir, { recursive: true, force: true });
});

/** Two faux providers, each configured by its own env var, like real providers. */
function makeModels(credentials: CredentialStore): MutableModels {
  const models = createModels({ credentials });
  const faux = fauxProvider({ provider: "faux", models: [{ id: "m1" }] });
  const other = fauxProvider({ provider: "other", models: [{ id: "o1" }, { id: "o2" }] });
  models.setProvider({ ...faux.provider, auth: { apiKey: envApiKeyAuth("Faux", [FAUX_ENV]) } });
  models.setProvider({ ...other.provider, auth: { apiKey: envApiKeyAuth("Other", [OTHER_ENV]) } });
  return models;
}

function writeAuth(content: unknown): void {
  writeFileSync(join(agentDir, "auth.json"), typeof content === "string" ? content : JSON.stringify(content));
}

async function list(providerIds: string[] = []): Promise<unknown> {
  const out = await listModels(providerIds, makeModels);
  assert.ok(!out.includes("\n"), "output is exactly one line");
  return JSON.parse(out);
}

test("no credentials anywhere lists nothing", async () => {
  assert.deepEqual(await list(), []);
});

test("a provider whose env var is set is listed as provider/id", async () => {
  process.env[OTHER_ENV] = "x";
  assert.deepEqual(await list(), ["other/o1", "other/o2"]);
});

test("a provider with an auth.json entry is listed, without running its key command", async () => {
  const marker = join(agentDir, "ran");
  writeAuth({ faux: { type: "api_key", key: `!touch ${marker}` } });
  assert.deepEqual(await list(), ["faux/m1"]);
  assert.equal(existsSync(marker), false, "the key command never ran");
});

test("a pi OAuth login in auth.json counts, expired or not", async () => {
  writeAuth({ faux: { type: "oauth", access: "a", refresh: "r", expires: 1 } });
  assert.deepEqual(await list(), ["faux/m1"]);
});

test("provider ids passed in are listed without other credentials, unknown ones ignored", async () => {
  assert.deepEqual(await list(["other", "nobody"]), ["other/o1", "other/o2"]);
});

test("every credential source adds up, each provider once", async () => {
  process.env[FAUX_ENV] = "x";
  writeAuth({ faux: { type: "api_key", key: "k" } });
  assert.deepEqual(await list(["faux", "other"]), ["faux/m1", "other/o1", "other/o2"]);
});

test("a malformed auth.json is an error line naming the path", async () => {
  writeAuth("{ not json");
  const out = (await list()) as { type: string; code: string; message: string };
  assert.equal(out.type, "error");
  assert.equal(out.code, "provider");
  assert.match(out.message, new RegExp(`^cannot read pi credentials from ${join(agentDir, "auth.json")}`));
});
