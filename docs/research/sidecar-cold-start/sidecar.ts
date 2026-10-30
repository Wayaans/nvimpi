// Throwaway cold-start probe. Not the real sidecar.
import { createInterface } from "node:readline";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { AssistantEntry, createRegistry, defineExtension, Harness, MemoryStorage, section } from "@earendil-works/pi-durable";

// Redirect provider HTTP to the local mock so timing excludes the network.
const mock = process.env.MOCK_URL!;
const realFetch = globalThis.fetch;
globalThis.fetch = (input: any, init?: any) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  return realFetch(url.replace("https://api.anthropic.com", mock), init);
};

const systemPrompt = (text: string) =>
  defineExtension({ name: "nvimpi", sections: [section("system", () => text, { tag: false })] });

async function rewrite(user: string): Promise<string> {
  const models = createModels();
  models.setProvider(anthropicProvider());
  const registry = createRegistry();
  registry.install(systemPrompt("Return only the replacement text."));
  const harness = await Harness.open(
    new MemoryStorage(),
    { models, registry, settings: { retry: { enabled: false }, compaction: { enabled: false } } },
    BACKGROUND_CONTEXT,
  );
  try {
    const conversation = await harness.root(BACKGROUND_CONTEXT, { agent: { model: { provider: "anthropic", modelId: "claude-fable-5" } } });
    const submission = await conversation.submit({ type: "input", content: user }, BACKGROUND_CONTEXT);
    const settled = await submission.wait(BACKGROUND_CONTEXT);
    if (settled.status !== "done" || settled.type !== "input") throw new Error(`${settled.reason} ${JSON.stringify((settled as any).detail)}`);
    const answer = await conversation.commit((tx) => tx.entry(AssistantEntry, settled.answer), BACKGROUND_CONTEXT);
    const message = answer?.model?.[0];
    if (message?.role !== "assistant") throw new Error("no assistant message");
    return message.content.flatMap((b: any) => (b.type === "text" ? [b.text] : [])).join("");
  } finally {
    await harness.close(BACKGROUND_CONTEXT);
  }
}

const send = (msg: unknown) => process.stdout.write(JSON.stringify(msg) + "\n");
send({ type: "ready" });
createInterface({ input: process.stdin }).on("line", async (line) => {
  const req = JSON.parse(line);
  try {
    send({ type: "result", id: req.id, text: await rewrite(req.text) });
  } catch (e) {
    send({ type: "error", id: req.id, message: String(e) });
  }
});
