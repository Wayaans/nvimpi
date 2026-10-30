// Credentials for pi-ai: a read-only view of pi's auth.json, stacked in layers.
// When no layer has an entry for a provider, pi-ai falls back to that provider's env vars.
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";

/** A credential problem the user has to fix. The message is shown to them as is. */
export class CredentialError extends Error {}

const COMMAND_TIMEOUT_MS = 5_000;

/** `$PI_CODING_AGENT_DIR/auth.json` (a leading `~` expanded), else `~/.pi/agent/auth.json`, as pi does. */
export function authJsonPath(env: NodeJS.ProcessEnv = process.env): string {
  const dir = env.PI_CODING_AGENT_DIR;
  return join(dir ? expandHome(dir) : join(homedir(), ".pi", "agent"), "auth.json");
}

function expandHome(path: string): string {
  if (path === "~") return homedir();
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

/**
 * The first layer with an entry owns the provider: a later layer, or the env vars,
 * are never consulted for it, even when its entry is broken.
 */
export function layeredStore(layers: readonly CredentialStore[]): CredentialStore {
  async function owner(providerId: string): Promise<CredentialStore | undefined> {
    for (const layer of layers) {
      if (await layer.read(providerId)) return layer;
    }
    return undefined;
  }
  return {
    async read(providerId, options) {
      for (const layer of layers) {
        const credential = await layer.read(providerId, options);
        if (credential) return credential;
      }
      return undefined;
    },
    async list(options) {
      const byProvider = new Map<string, CredentialInfo>();
      for (const layer of layers) {
        for (const info of await layer.list(options)) {
          if (!byProvider.has(info.providerId)) byProvider.set(info.providerId, info);
        }
      }
      return [...byProvider.values()];
    },
    async modify(providerId, fn, options) {
      const layer = await owner(providerId);
      if (!layer) throw new CredentialError(`no stored ${providerId} credential to change`);
      return layer.modify(providerId, fn, options);
    },
    async delete(providerId, options) {
      await (await owner(providerId))?.delete(providerId, options);
    },
  };
}

/**
 * pi's auth.json, read directly and never written. API keys resolve like pi's: a literal,
 * `$ENV` / `${ENV}`, or `!command`. Each entry resolves at most once per store, so one
 * request runs a key command once. A missing file has no entries.
 */
export function authJsonStore(path: string): CredentialStore {
  let entries: Promise<Record<string, unknown>> | undefined;
  const resolved = new Map<string, Promise<Credential | undefined>>();
  const load = () => (entries ??= loadAuthJson(path));

  async function resolveEntry(providerId: string): Promise<Credential | undefined> {
    const entry = (await load())[providerId];
    if (entry === undefined) return undefined;
    const credential = parseEntry(entry);
    if (!credential) throw new CredentialError(`invalid ${providerId} entry in ${path}`);
    if (credential.type === "oauth" || credential.key === undefined) return credential;
    return { ...credential, key: await resolveKey(credential.key, credential.env ?? {}, providerId, path) };
  }

  return {
    read(providerId) {
      let credential = resolved.get(providerId);
      if (!credential) {
        credential = resolveEntry(providerId);
        resolved.set(providerId, credential);
      }
      return credential;
    },
    // Never runs key commands. Entries of an unknown shape are left out.
    async list() {
      return Object.entries(await load()).flatMap(([providerId, entry]) => {
        const credential = parseEntry(entry);
        return credential ? [{ providerId, type: credential.type }] : [];
      });
    },
    // pi-ai calls modify only to refresh an expiring OAuth token. Refreshing rotates the
    // refresh token, so a refresh nvimpi failed to persist would log the user out of pi.
    async modify(providerId) {
      const entry = parseEntry((await load())[providerId]);
      throw new CredentialError(
        entry?.type === "oauth"
          ? `${providerId} login in ${path} has expired: open pi to refresh your ${providerId} login`
          : `nvimpi never writes ${path}`,
      );
    },
    async delete() {
      throw new CredentialError(`nvimpi never writes ${path}`);
    },
  };
}

async function loadAuthJson(path: string): Promise<Record<string, unknown>> {
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch (cause) {
    if (isErrnoException(cause) && cause.code === "ENOENT") return {};
    throw new CredentialError(`cannot read pi credentials from ${path}: ${messageOf(cause)}`);
  }
  let value: unknown;
  try {
    value = JSON.parse(text.replace(/^﻿/, ""));
  } catch (cause) {
    throw new CredentialError(`cannot read pi credentials from ${path}: ${messageOf(cause)}`);
  }
  if (!isRecord(value)) throw new CredentialError(`cannot read pi credentials from ${path}: expected a JSON object`);
  return value;
}

/** The entry as a pi-ai credential (unknown fields kept), or undefined if its shape is invalid. */
function parseEntry(entry: unknown): Credential | undefined {
  if (!isRecord(entry)) return undefined;
  if (entry.type === "api_key") {
    const { key, env } = entry;
    if (key !== undefined && typeof key !== "string") return undefined;
    if (env !== undefined && !(isRecord(env) && Object.values(env).every((value) => typeof value === "string"))) {
      return undefined;
    }
    return { ...entry, type: "api_key", key, env: env as Record<string, string> | undefined };
  }
  if (entry.type === "oauth") {
    const { access, refresh, expires } = entry;
    if (typeof access !== "string" || typeof refresh !== "string") return undefined;
    if (typeof expires !== "number" || !Number.isFinite(expires)) return undefined;
    return { ...entry, type: "oauth", access, refresh, expires };
  }
  return undefined;
}

/** pi's key syntax: `!command`, else a template where `$NAME` / `${NAME}` read env and `$$` / `$!` escape. */
async function resolveKey(key: string, entryEnv: Record<string, string>, providerId: string, path: string): Promise<string> {
  const resolved = key.startsWith("!")
    ? await runKeyCommand(key.slice(1), `${providerId} key command in ${path}`)
    : interpolate(key, entryEnv, `${providerId} key in ${path}`);
  if (resolved === "") throw new CredentialError(`${providerId} key in ${path} is empty`);
  return resolved;
}

const TEMPLATE = /\$(?:(\$)|(!)|\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g;

function interpolate(template: string, entryEnv: Record<string, string>, what: string): string {
  const missing: string[] = [];
  const value = template.replace(TEMPLATE, (_match, dollar?: string, bang?: string, braced?: string, bare?: string) => {
    if (dollar || bang) return dollar ?? bang ?? "";
    const name = braced ?? bare ?? "";
    // Empty counts as unset, as in pi.
    const found = entryEnv[name] || process.env[name];
    if (!found) missing.push(`$${name}`);
    return found ?? "";
  });
  if (missing.length === 1) throw new CredentialError(`${what} uses ${missing[0]}, which is not set`);
  if (missing.length > 1) throw new CredentialError(`${what} uses ${missing.join(", ")}, which are not set`);
  return value;
}

/** Runs `command` in `sh` and returns its trimmed stdout. On timeout the whole process group is killed. */
function runKeyCommand(command: string, what: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn("/bin/sh", ["-c", command], { detached: true, stdio: ["ignore", "pipe", "ignore"] });
    const chunks: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
    const timer = setTimeout(() => {
      if (child.pid !== undefined) process.kill(-child.pid, "SIGKILL");
      reject(new CredentialError(`${what} timed out after ${COMMAND_TIMEOUT_MS / 1000} s: ${command}`));
    }, COMMAND_TIMEOUT_MS);
    child.on("error", (cause) => {
      clearTimeout(timer);
      reject(new CredentialError(`${what} failed (${cause.message}): ${command}`));
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new CredentialError(`${what} failed (${code === null ? `signal ${signal}` : `exit ${code}`}): ${command}`));
        return;
      }
      const output = Buffer.concat(chunks).toString("utf8").trim();
      if (output === "") reject(new CredentialError(`${what} printed nothing: ${command}`));
      else resolve(output);
    });
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isErrnoException(value: unknown): value is NodeJS.ErrnoException {
  return value instanceof Error && "code" in value;
}

function messageOf(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}
