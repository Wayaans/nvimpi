// Sidecar entry: reads one request line from stdin (Lua closes stdin after it),
// writes exactly one response line to stdout, then exits. Logs go to stderr only.
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { handleRequest } from "./handler.ts";

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

async function main(): Promise<void> {
  const input = await readStdin();
  const line = input.split("\n", 1)[0] ?? "";
  const response = await handleRequest(line, builtinModels());
  // Exit once the line is flushed: provider SDKs can keep sockets open.
  process.stdout.write(`${response}\n`, () => process.exit(0));
}

main().catch((cause: unknown) => {
  console.error(cause);
  process.exitCode = 1;
});
