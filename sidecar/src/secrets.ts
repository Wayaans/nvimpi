// The credential values one sidecar run has seen, so every message it emits can show them as `***`.
import type { AuthResult, Credential, CredentialStore } from "@earendil-works/pi-ai";

export type Secrets = {
  add(value: string | null | undefined): void;
  /** `text` with every known secret replaced by `***`. */
  redact(text: string): string;
};

/**
 * Shorter values are not secrets worth redacting: no real key or token is that short, and
 * replacing them would garble ordinary words in every message.
 */
const MIN_SECRET_LENGTH = 8;

export function createSecrets(): Secrets {
  const values = new Set<string>();
  return {
    add(value) {
      if (value && value.length >= MIN_SECRET_LENGTH) values.add(value);
    },
    redact(text) {
      // Longest first, so a secret containing another is replaced whole.
      return [...values].sort((a, b) => b.length - a.length).reduce((out, value) => out.replaceAll(value, "***"), text);
    },
  };
}

/** `store`, adding the secret fields of every credential it hands out to `secrets`. */
export function recordingStore(store: CredentialStore, secrets: Secrets): CredentialStore {
  return {
    ...store,
    async read(providerId, options) {
      const credential = await store.read(providerId, options);
      if (credential) addCredential(credential, secrets);
      return credential;
    },
  };
}

function addCredential(credential: Credential, secrets: Secrets): void {
  if (credential.type === "api_key") {
    secrets.add(credential.key);
  } else {
    secrets.add(credential.access);
    secrets.add(credential.refresh);
  }
}

/** The request auth pi-ai resolved: a key from an env var, or a token derived from a login. */
export function addAuth(result: AuthResult, secrets: Secrets): void {
  secrets.add(result.auth.apiKey);
  for (const value of Object.values(result.auth.headers ?? {})) secrets.add(value);
}
