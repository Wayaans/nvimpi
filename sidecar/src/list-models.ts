// `--list-models`: the models the user can pick, from providers that have credentials.
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

/**
 * One line: a JSON array of "provider/id" for every provider that has an auth.json entry,
 * a set env var, or is named in `providerIds` (the providers with a setup() key in Lua).
 * Side-effect free: auth.json key commands never run and OAuth tokens are never refreshed.
 * A broken auth.json gives an error line in the request response shape.
 */
export async function listModels(providerIds: readonly string[], createModels: CreateModels): Promise<string> {
  let stored: string[];
  try {
    stored = (await authJsonStore(authJsonPath()).list()).map((info) => info.providerId);
  } catch (cause) {
    if (!(cause instanceof CredentialError)) throw cause;
    const response: Response = { type: "error", code: "provider", message: cause.message };
    return JSON.stringify(response);
  }
  const named = new Set([...providerIds, ...stored]);
  const models = createModels(NO_ENTRIES);
  const listed: string[] = [];
  for (const provider of models.getProviders()) {
    if (named.has(provider.id) || (await models.checkAuth(provider.id))) {
      listed.push(...models.getModels(provider.id).map((model) => `${provider.id}/${model.id}`));
    }
  }
  return JSON.stringify(listed);
}
