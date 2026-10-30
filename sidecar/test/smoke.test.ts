// Runs the committed bundle as Lua does: a separate process, from a directory with no node_modules.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

const BUNDLE = new URL("../dist/sidecar.mjs", import.meta.url).pathname;
let dir: string;

before(() => {
  dir = mkdtempSync(join(tmpdir(), "nvimpi-smoke-"));
  copyFileSync(BUNDLE, join(dir, "sidecar.mjs"));
});

after(() => rmSync(dir, { recursive: true, force: true }));

function run(stdin: string): unknown {
  // No provider env vars, and HOME points at the empty dir.
  const result = spawnSync(process.execPath, ["sidecar.mjs"], {
    cwd: dir,
    input: stdin,
    env: { PATH: process.env.PATH, HOME: dir },
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
