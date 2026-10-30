import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Models } from "@earendil-works/pi-ai";
import { AssistantEntry, createRegistry, defineExtension, Harness, MemoryStorage, section } from "@earendil-works/pi-durable";

export type Completion = { ok: true; text: string } | { ok: false; reason: string; detail?: string };

/**
 * One pi-durable turn with nothing persisted: a fresh Harness over MemoryStorage,
 * no tools, retries and compaction off. `system` is installed verbatim as an
 * untagged section (agent.instructions would wrap it in <instructions> tags).
 */
export async function completeOnce(
  models: Models,
  model: { provider: string; modelId: string },
  system: string,
  user: string,
): Promise<Completion> {
  const registry = createRegistry();
  registry.install(defineExtension({ name: "nvimpi", sections: [section("system", () => system, { tag: false })] }));

  const harness = await Harness.open(
    new MemoryStorage(),
    { models, registry, settings: { retry: { enabled: false }, compaction: { enabled: false } } },
    BACKGROUND_CONTEXT,
  );
  try {
    const conversation = await harness.root(BACKGROUND_CONTEXT, { agent: { model } });
    const submission = await conversation.submit({ type: "input", content: user }, BACKGROUND_CONTEXT);
    const settled = await submission.wait(BACKGROUND_CONTEXT);
    if (settled.type !== "input" || settled.status !== "done") {
      const detail = settled.status === "unanswered" ? settled.detail : undefined;
      return {
        ok: false,
        reason: settled.status === "unanswered" ? settled.reason : settled.status,
        detail: detail === undefined ? undefined : typeof detail === "string" ? detail : JSON.stringify(detail),
      };
    }
    const answer = await conversation.commit((tx) => tx.entry(AssistantEntry, settled.answer), BACKGROUND_CONTEXT);
    const message = answer?.model?.[0];
    if (message?.role !== "assistant") return { ok: false, reason: "no assistant message" };
    return { ok: true, text: message.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("") };
  } finally {
    await harness.close(BACKGROUND_CONTEXT);
  }
}
