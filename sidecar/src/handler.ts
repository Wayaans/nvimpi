import type { CredentialStore, Models } from "@earendil-works/pi-ai";
import { authJsonPath, authJsonStore, CredentialError, layeredStore, requestKeyStore } from "./credentials.ts";
import { completeOnce } from "./durable.ts";
import { addAuth, createSecrets, recordingStore } from "./secrets.ts";
import type { Secrets } from "./secrets.ts";
import { isRecord, messageOf } from "./values.ts";

/** One request line from Lua. `before + selection + after` is a verbatim stretch of the buffer. */
export type Request = {
  mode: "rewrite" | "insert";
  instruction: string;
  before: string;
  selection: string;
  after: string;
  filetype: string;
  model: { provider: string; id: string };
  /** The key from setup() for `model.provider`. Never logged, and redacted from every error. */
  api_key?: string;
};

type ErrorCode = "not_configured" | "provider" | "invalid_request" | "internal";

export type Response = { type: "result"; text: string } | { type: "error"; code: ErrorCode; message: string };

export function errorResponse(code: ErrorCode, message: string): Response {
  return { type: "error", code, message };
}

/** Builds the model collection for one request over its credentials. */
export type CreateModels = (credentials: CredentialStore) => Models;

/**
 * Turns one request line into exactly one response line (no trailing newline).
 * Every credential resolved on the way is added to `secrets`, and redacted from the response.
 */
export async function handleRequest(line: string, createModels: CreateModels, secrets: Secrets = createSecrets()): Promise<string> {
  const response = await respond(line, createModels, secrets);
  // A provider can echo the key it rejected; no credential leaves the sidecar.
  return JSON.stringify(response.type === "error" ? { ...response, message: secrets.redact(response.message) } : response);
}

async function respond(line: string, createModels: CreateModels, secrets: Secrets): Promise<Response> {
  const request = parseRequest(line);
  if (typeof request === "string") return errorResponse("invalid_request", `invalid request: ${request}`);
  secrets.add(request.api_key);
  return answer(request, createModels, secrets);
}

async function answer(request: Request, createModels: CreateModels, secrets: Secrets): Promise<Response> {
  const { provider, id } = request.model;
  // Credential layers, first match wins; provider env vars come after all of them (pi-ai).
  const setupKey = request.api_key === undefined ? [] : [requestKeyStore(provider, request.api_key)];
  const store = layeredStore([...setupKey, authJsonStore(authJsonPath())]);
  const models = createModels(recordingStore(store, secrets));

  if (!models.getModel(provider, id)) {
    return errorResponse("not_configured", `unknown model ${provider}/${id}: run :NvimpiModel`);
  }
  try {
    const auth = await models.getAuth(provider);
    if (!auth) {
      return errorResponse("not_configured", `no credentials for ${provider}: log in with pi, or set its API key env var`);
    }
    addAuth(auth, secrets);
  } catch (cause) {
    const problem = credentialProblem(cause);
    return errorResponse("provider", problem ? problem.message : `${provider} credentials: ${messageOf(cause)}`);
  }

  try {
    const completion = await completeOnce(models, { provider, modelId: id }, systemPrompt(request), userMessage(request));
    if (!completion.ok) {
      return completion.reason === "model_error"
        ? errorResponse("provider", `${provider}/${id}: ${completion.detail ?? "model error"}`)
        : errorResponse("internal", `pi-durable: ${completion.reason}${completion.detail ? `: ${completion.detail}` : ""}`);
    }
    return { type: "result", text: cleanReply(completion.text, request) };
  } catch (cause) {
    return errorResponse("internal", `internal error: ${messageOf(cause)}`);
  }
}

/** pi-ai wraps credential store failures; find ours in the cause chain. */
function credentialProblem(cause: unknown): CredentialError | undefined {
  for (let current = cause; current instanceof Error; current = current.cause) {
    if (current instanceof CredentialError) return current;
  }
  return undefined;
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
  const { mode, instruction, before, selection, after, filetype, model, api_key } = value;
  if (mode !== "rewrite" && mode !== "insert") return 'mode must be "rewrite" or "insert"';
  if (typeof instruction !== "string") return "instruction must be a string";
  if (typeof before !== "string") return "before must be a string";
  if (typeof selection !== "string") return "selection must be a string";
  if (typeof after !== "string") return "after must be a string";
  if (typeof filetype !== "string") return "filetype must be a string";
  if (!isRecord(model) || !isNonEmptyString(model.provider) || !isNonEmptyString(model.id)) {
    return "model must be { provider, id } with non-empty strings";
  }
  if (api_key !== undefined && !isNonEmptyString(api_key)) return "api_key must be a non-empty string";
  return {
    mode,
    instruction,
    before,
    selection,
    after,
    filetype,
    model: { provider: model.provider, id: model.id },
    ...(api_key === undefined ? {} : { api_key }),
  };
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
    "The rest of the file is Context: do not repeat any of it.",
    "Match the indentation and style of the Context.",
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

/**
 * Strips a code fence wrapped around the whole reply, and a trailing newline the selection did not have.
 * An Insert's selection is "", so its reply never ends in a newline that would split the cursor line.
 */
function cleanReply(text: string, request: Request): string {
  let reply = FENCED.exec(text)?.[1] ?? text;
  if (reply.endsWith("\n") && !request.selection.endsWith("\n")) {
    reply = reply.slice(0, -1);
  }
  return reply;
}
