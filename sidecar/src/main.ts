// Sidecar entry: reads one request line from stdin (Lua closes stdin after it), or with
// `--list-models [provider ids...]` lists the models the user can pick, or with
// `--credential-source <provider>` reports which source covers that provider. Either way it writes
// exactly one line to stdout, then exits. Logs go to stderr only, with every credential redacted.
import { text } from "node:stream/consumers";
import { format } from "node:util";
import { registerBunOAuthFlows } from "@earendil-works/pi-ai/bun-oauth";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { handleRequest } from "./handler.ts";
import type { CreateModels } from "./handler.ts";
import { credentialSource, listModels } from "./list-models.ts";
import { createSecrets } from "./secrets.ts";

const secrets = createSecrets();

/** Lua shows the stderr tail when the sidecar crashes, so every log line is redacted first. */
function logRedacted(...args: unknown[]): void {
  process.stderr.write(`${secrets.redact(format(...args))}\n`);
}

// Library logging too; console.log moves to stderr so stdout stays the one response line.
console.log = console.info = console.warn = console.error = console.debug = logRedacted;

function crash(cause: unknown): void {
  process.stderr.write(`${secrets.redact(format(cause))}\n`, () => process.exit(1));
}

process.on("uncaughtException", crash);
process.on("unhandledRejection", crash);

async function main(): Promise<void> {
  // pi-ai loads OAuth flows through an import esbuild cannot follow; this embeds them in the bundle.
  registerBunOAuthFlows();
  const createModels: CreateModels = (credentials) => builtinModels({ credentials });
  const [flag, ...providerIds] = process.argv.slice(2);
  let response: string;
  if (flag === "--list-models") {
    response = await listModels(providerIds, createModels);
  } else if (flag === "--credential-source") {
    response = await credentialSource(providerIds[0] ?? "", createModels);
  } else {
    const input = await text(process.stdin);
    response = await handleRequest(input.split("\n", 1)[0] ?? "", createModels, secrets);
  }
  // Exit once the line is flushed: provider SDKs can keep sockets open.
  process.stdout.write(`${response}\n`, () => process.exit(0));
}

main().catch(crash);
