// `--list-models`: the models the user can pick, from providers that have credentials.
// `--credential-source <provider>`: which source covers one provider, for :checkhealth.
// Both are side-effect free: auth.json key commands never run and OAuth tokens are never refreshed.
import type { CredentialStore } from "@earendil-works/pi-ai";
import { authJsonPath, authJsonStore, CredentialError } from "./credentials.ts";
import type { CreateModels, Response } from "./handler.ts";

/** A store with no entries, so pi-ai checks only the provider's env vars and ambient sources. */
const NO_ENTRIES: CredentialStore = {
  async read() {
    return undefined;
  },
  async list() {
    return [];
  },
  async modify() {
    throw new CredentialError("nvimpi never stores credentials");
  },
  async delete() {},
};

/** Providers with an auth.json entry, or the error line when auth.json is broken. */
async function storedProviders(): Promise<{ ok: true; ids: string[] } | { ok: false; line: string }> {
  try {
    return { ok: true, ids: (await authJsonStore(authJsonPath()).list()).map((info) => info.providerId) };
  } catch (cause) {
    if (!(cause instanceof CredentialError)) throw cause;
    const response: Response = { type: "error", code: "provider", message: cause.message };
    return { ok: false, line: JSON.stringify(response) };
  }
}

/**
 * One line: a JSON array of "provider/id" for every provider that has an auth.json entry,
 * a set env var, or is named in `providerIds` (the providers with a setup() key in Lua).
 * A broken auth.json gives an error line in the request response shape.
 */
export async function listModels(providerIds: readonly string[], createModels: CreateModels): Promise<string> {
  const stored = await storedProviders();
  if (!stored.ok) return stored.line;
  const named = new Set([...providerIds, ...stored.ids]);
  const models = createModels(NO_ENTRIES);
  const listed: string[] = [];
  for (const provider of models.getProviders()) {
    if (named.has(provider.id) || (await models.checkAuth(provider.id))) {
      listed.push(...models.getModels(provider.id).map((model) => `${provider.id}/${model.id}`));
    }
  }
  return JSON.stringify(listed);
}

/** "env" covers pi-ai's env vars and ambient sources (checkAuth over a store with no entries). */
export type CredentialSource = "auth.json" | "env" | "none" | "unknown";

/**
 * One line: `{"type":"source","source":...}` naming what covers `providerId` when a request has
 * no setup() key, in the order requests use: auth.json, then env. A broken auth.json gives an error line.
 */
export async function credentialSource(providerId: string, createModels: CreateModels): Promise<string> {
  const stored = await storedProviders();
  if (!stored.ok) return stored.line;
  const models = createModels(NO_ENTRIES);
  let source: CredentialSource;
  if (!models.getProviders().some((provider) => provider.id === providerId)) source = "unknown";
  else if (stored.ids.includes(providerId)) source = "auth.json";
  else if (await models.checkAuth(providerId)) source = "env";
  else source = "none";
  return JSON.stringify({ type: "source", source });
}
