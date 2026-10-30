import type { Models } from "@earendil-works/pi-ai";
import { completeOnce } from "./durable.ts";

/** One request line from Lua. `before + selection + after` is a verbatim stretch of the buffer. */
export type Request = {
  mode: "rewrite" | "insert";
  instruction: string;
  before: string;
  selection: string;
  after: string;
  filetype: string;
  model: { provider: string; id: string };
};

type ErrorCode = "not_configured" | "provider" | "invalid_request" | "internal";

export type Response = { type: "result"; text: string } | { type: "error"; code: ErrorCode; message: string };

/** Turns one request line into exactly one response line (no trailing newline). */
export async function handleRequest(line: string, models: Models): Promise<string> {
  return JSON.stringify(await respond(line, models));
}

async function respond(line: string, models: Models): Promise<Response> {
  const parsed = parseRequest(line);
  if (typeof parsed === "string") return error("invalid_request", `invalid request: ${parsed}`);
  const request = parsed;
  const { provider, id } = request.model;

  if (!models.getModel(provider, id)) {
    return error("not_configured", `unknown model ${provider}/${id}: run :NvimpiModel`);
  }
  try {
    if (!(await models.getAuth(provider))) {
      return error("not_configured", `no credentials for ${provider}: log in with pi, or set its API key env var`);
    }
  } catch (cause) {
    return error("provider", `${provider} credentials: ${messageOf(cause)}`);
  }

  try {
    const completion = await completeOnce(models, { provider, modelId: id }, systemPrompt(request), userMessage(request));
    if (!completion.ok) {
      return completion.reason === "model_error"
        ? error("provider", `${provider}/${id}: ${completion.detail ?? "model error"}`)
        : error("internal", `pi-durable: ${completion.reason}${completion.detail ? `: ${completion.detail}` : ""}`);
    }
    return { type: "result", text: cleanReply(completion.text, request) };
  } catch (cause) {
    return error("internal", `internal error: ${messageOf(cause)}`);
  }
}

function error(code: ErrorCode, message: string): Response {
  return { type: "error", code, message };
}

function messageOf(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

/** Returns the request, or a reason it is invalid. */
function parseRequest(line: string): Request | string {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    return "not JSON";
  }
  if (!isRecord(value)) return "expected a JSON object";
  const { mode, instruction, before, selection, after, filetype, model } = value;
  if (mode !== "rewrite" && mode !== "insert") return 'mode must be "rewrite" or "insert"';
  for (const [name, field] of Object.entries({ instruction, before, selection, after, filetype })) {
    if (typeof field !== "string") return `${name} must be a string`;
  }
  if (!isRecord(model) || !isNonEmptyString(model.provider) || !isNonEmptyString(model.id)) {
    return "model must be { provider, id } with non-empty strings";
  }
  return {
    mode,
    instruction: instruction as string,
    before: before as string,
    selection: selection as string,
    after: after as string,
    filetype: filetype as string,
    model: { provider: model.provider, id: model.id },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

/** A selection that starts and ends on line boundaries, as in a linewise selection. */
function isWholeLines(request: Request): boolean {
  return (
    request.selection !== "" &&
    (request.before === "" || request.before.endsWith("\n")) &&
    (request.after === "" || request.after.startsWith("\n"))
  );
}

function systemPrompt(request: Request): string {
  const language = request.filetype === "" ? "a plain text file" : `a ${request.filetype} file`;
  const shared = [
    "Reply with only that text, exactly as it should appear in the file.",
    "Do not add explanations, comments about the change, or code fences.",
    "Do not repeat any of the surrounding text.",
    "Match the indentation and style of the surrounding text.",
  ];
  switch (request.mode) {
    case "rewrite":
      return [
        `You edit ${language}. The user marks a selection with <selection> and </selection> and gives an instruction.`,
        "Rewrite the selected text following the instruction. Return only the replacement text for the selection.",
        ...shared,
        ...(isWholeLines(request) ? ["The selection is whole lines: do not end the reply with a trailing newline."] : []),
      ].join("\n");
    case "insert":
      return [
        `You edit ${language}. The user marks the cursor with <cursor/> and gives an instruction.`,
        "Write the text to insert at the cursor following the instruction. Return only the text to insert.",
        ...shared,
      ].join("\n");
  }
}

function userMessage(request: Request): string {
  const marked =
    request.mode === "rewrite"
      ? `${request.before}<selection>${request.selection}</selection>${request.after}`
      : `${request.before}<cursor/>${request.after}`;
  return `Instruction: ${request.instruction}\n\nFile:\n${marked}`;
}

const FENCED = /^\s*```[^\n`]*\n([\s\S]*?)\n?```\s*$/;

/** Strips a code fence wrapped around the whole reply, and a trailing newline the selection did not have. */
function cleanReply(text: string, request: Request): string {
  let reply = FENCED.exec(text)?.[1] ?? text;
  if (request.mode === "rewrite" && reply.endsWith("\n") && !request.selection.endsWith("\n")) {
    reply = reply.slice(0, -1);
  }
  return reply;
}
