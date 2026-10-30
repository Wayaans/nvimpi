// Sidecar entry: reads one request line from stdin (Lua closes stdin after it), or with
// `--list-models [provider ids...]` lists the models the user can pick, or with
// `--credential-source <provider>` reports which source covers that provider. Either way it writes
// exactly one line to stdout, then exits. Logs go to stderr only.
import { registerBunOAuthFlows } from "@earendil-works/pi-ai/bun-oauth";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { handleRequest } from "./handler.ts";
import type { CreateModels } from "./handler.ts";
import { credentialSource, listModels } from "./list-models.ts";

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

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
    const input = await readStdin();
    response = await handleRequest(input.split("\n", 1)[0] ?? "", createModels);
  }
  // Exit once the line is flushed: provider SDKs can keep sockets open.
  process.stdout.write(`${response}\n`, () => process.exit(0));
}

main().catch((cause: unknown) => {
  console.error(cause);
  process.exitCode = 1;
});
