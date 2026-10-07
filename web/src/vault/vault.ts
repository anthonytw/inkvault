// Opening a vault (format.md §2, §3.1) and reading one revision file (§4, §5):
// age decryption with typage, the `SMPR` framing, the HMAC tag under the
// vault secret, gunzip and JSON. Nothing here touches the network or the DOM.

import { Decrypter, armor, identityToRecipient } from "age-encryption";
import { DecodeError, arr, isObject, obj, opt, reqWith, str, uuid } from "../format/json.ts";
import { parseRevisionName, revisionFilename } from "../format/ids.ts";
import { type Revision, decodeRevision } from "../format/model.ts";
import { parseRFC3339 } from "../format/rfc3339.ts";
import { gunzip } from "./gzip.ts";

/** format.md §9 limits. */
export const limits = {
  revisionBytes: 256 * 1024 * 1024,
  manifestBytes: 16 * 1024 * 1024,
};

export type VaultErrorCode =
  | "manifestCorrupt" | "unsupportedFormat" | "legacyVault" | "badIdentity" | "classicIdentity" | "wrongKey"
  | "invalidVaultSecret";

/** Why a vault cannot be opened or unlocked. */
export class VaultError extends Error {
  constructor(public readonly code: VaultErrorCode, message: string) {
    super(message);
    this.name = "VaultError";
  }
}

export type RevisionErrorCode = "undecryptable" | "tagMismatch" | "corruptBody" | "undecodable";

/** Why one revision file could not be read; reported, never silently dropped (§4). */
export class RevisionReadError extends Error {
  constructor(public readonly code: RevisionErrorCode, message: string) {
    super(message);
    this.name = "RevisionReadError";
  }
}

export interface ManifestRecipient {
  key: string;
  label: string;
}

export interface VaultManifest {
  format: string;
  vaultId: string;
  recipients: ManifestRecipient[];
  vaultSecret: string;
  features: string[];
}

const bech32 = /^[02-9ac-hj-np-z]+$/;

/** An age recipient's type by its Bech32 prefix, or undefined if malformed. */
export function recipientType(key: string): "mlkem768x25519" | "x25519" | undefined {
  const k = key.toLowerCase();
  if (key !== k && key !== key.toUpperCase()) return undefined;
  if (k.startsWith("age1pq1") && bech32.test(k.slice(7)) && k.length > 20) return "mlkem768x25519";
  if (k.startsWith("age1") && bech32.test(k.slice(4)) && k.length === 62) return "x25519";
  return undefined;
}

/** Parses and validates `vault.json` (format.md §2). */
export function parseManifest(bytes: Uint8Array): VaultManifest {
  if (bytes.length > limits.manifestBytes) throw new VaultError("manifestCorrupt", "vault.json is larger than 16 MiB");
  let json: unknown;
  try {
    json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch (e) {
    throw new VaultError("manifestCorrupt", `vault.json is not JSON: ${String(e)}`);
  }
  let m: VaultManifest;
  try {
    const o = obj(json, "$");
    const recipients = reqWith(o, "recipients", "$", (v, p) => arr(v, p).map((r, i) => {
      const ro = obj(r, `${p}[${i}]`);
      const added = reqWith(ro, "added", `${p}[${i}]`, str);
      if (parseRFC3339(added) === undefined) throw new DecodeError(`${p}[${i}].added: bad date`);
      return { key: reqWith(ro, "key", `${p}[${i}]`, str), label: reqWith(ro, "label", `${p}[${i}]`, str) };
    }));
    const created = reqWith(o, "created", "$", str);
    if (parseRFC3339(created) === undefined) throw new DecodeError("$.created: bad date");
    const features = opt(o, "features");
    m = {
      format: reqWith(o, "format", "$", str),
      vaultId: reqWith(o, "vaultId", "$", uuid),
      recipients,
      vaultSecret: reqWith(o, "vaultSecret", "$", str),
      features: Array.isArray(features) ? features.filter((f): f is string => typeof f === "string") : [],
    };
  } catch (e) {
    throw new VaultError("manifestCorrupt", e instanceof Error ? e.message : String(e));
  }
  if (m.format !== "sempere/1") throw new VaultError("unsupportedFormat", `unsupported vault format ${m.format}`);
  if (m.recipients.length === 0) throw new VaultError("manifestCorrupt", "no recipients");
  for (const r of m.recipients) {
    if (!recipientType(r.key)) throw new VaultError("manifestCorrupt", `invalid recipient ${r.key.slice(0, 24)}…`);
  }
  if (new Set(m.recipients.map((r) => r.key)).size !== m.recipients.length) {
    throw new VaultError("manifestCorrupt", "duplicate recipient");
  }
  return m;
}

/** True when the vault lists an X25519 recipient: migrate-only (format.md §3.3.2). */
export function isLegacy(m: VaultManifest): boolean {
  return m.recipients.some((r) => recipientType(r.key) === "x25519");
}

/**
 * The identity in pasted text: an `age-keygen -pq` file or the bare
 * `AGE-SECRET-KEY-PQ-1…` line. Comments and blank lines are ignored.
 */
export function parseIdentity(text: string): string {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0 && !l.startsWith("#"));
  const pq = lines.filter((l) => l.toUpperCase().startsWith("AGE-SECRET-KEY-PQ-1"));
  if (pq.length > 1) throw new VaultError("badIdentity", "paste one key, not several");
  const [key] = pq;
  if (key !== undefined) return key.toUpperCase();
  if (lines.some((l) => l.toUpperCase().startsWith("AGE-SECRET-KEY-1"))) {
    throw new VaultError("classicIdentity",
      "this is a classic (X25519) key; Sempere vaults use post-quantum keys (AGE-SECRET-KEY-PQ-1…)");
  }
  throw new VaultError("badIdentity", "no AGE-SECRET-KEY-PQ-1… key found in the pasted text");
}

const encoder = new TextEncoder();

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

const magic = [0x53, 0x4d, 0x50, 0x52];
const headerSize = 37;

function buf(b: Uint8Array): Uint8Array<ArrayBuffer> {
  return b as Uint8Array<ArrayBuffer>;
}

async function hmacKey(secret: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", buf(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

async function hkdfKey(secret: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", buf(secret), "HKDF", false, ["deriveKey"]);
}

/** An unlocked vault: the identity and the vault secret, in memory only. */
export class UnlockedVault {
  private constructor(
    readonly manifest: VaultManifest,
    private readonly decrypter: Decrypter,
    private readonly secret: CryptoKey,
    private readonly previous: CryptoKey | undefined,
    /** The recipient of the pasted identity. */
    readonly recipient: string,
    /** The vault secret (then the previous one) as HKDF input, for derived keys (format.md §12). */
    private readonly derivation: CryptoKey[] = [],
  ) {}

  /**
   * The keys derived for `info` (HKDF-SHA256, empty salt, format.md §10, §12)
   * under the current secret and, during an unfinished rewrap, the previous one.
   */
  async derivedKeys(info: string, algorithm: AesKeyGenParams, usages: KeyUsage[]): Promise<CryptoKey[]> {
    return Promise.all(this.derivation.map((k) => crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode(info) }, k, algorithm, false, usages)));
  }

  /**
   * Decrypts `vault.json`'s secret with `identity` (and, while a rewrap is
   * unfinished, the journal's previous secret, §3.3.1).
   */
  static async unlock(manifest: VaultManifest, identity: string, journal?: Uint8Array): Promise<UnlockedVault> {
    if (isLegacy(manifest)) {
      throw new VaultError("legacyVault",
        "this vault still lists a classic X25519 key; migrate it with the app or `sempere vault` first (format.md §3.3.2)");
    }
    let recipient: string;
    const decrypter = new Decrypter();
    try {
      recipient = await identityToRecipient(identity);
      decrypter.addIdentity(identity);
    } catch (e) {
      throw new VaultError("badIdentity", `the key is not a valid age identity: ${String(e)}`);
    }
    const secretBytes = await decryptSecret(decrypter, manifest.vaultSecret);
    const secret = await hmacKey(secretBytes);
    const derivation = [await hkdfKey(secretBytes)];
    let previous: CryptoKey | undefined;
    if (journal) {
      try {
        const o = obj(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(journal)), "$");
        const p = opt(o, "previousVaultSecret");
        if (typeof p === "string") {
          const bytes = await decryptSecret(decrypter, p);
          previous = await hmacKey(bytes);
          derivation.push(await hkdfKey(bytes));
        }
      } catch {
        // An unreadable journal only matters for files not yet re-tagged; they
        // then fail their tag check and are reported.
      }
    }
    return new UnlockedVault(manifest, decrypter, secret, previous, recipient, derivation);
  }

  /**
   * The keyed blob names (format.md §8.1.2) for a content hash (32 raw
   * bytes): under the current vault secret, then, while a rewrap is
   * unfinished, under the previous one (§8.1.5).
   */
  async blobNames(sha256: Uint8Array): Promise<string[]> {
    const message = concat([encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode("blob"), Uint8Array.of(0), sha256]);
    const keys = this.previous ? [this.secret, this.previous] : [this.secret];
    const out: string[] = [];
    for (const k of keys) out.push(hex(new Uint8Array(await crypto.subtle.sign("HMAC", k, buf(message)))));
    return out;
  }

  /** Decrypts an age file as a stream (blobs, format.md §8.1.3): authenticated chunk by chunk. */
  async decryptStream(file: ReadableStream<Uint8Array>): Promise<ReadableStream<Uint8Array>> {
    return this.decrypter.decrypt(file);
  }

  /**
   * Reads one revision file (§4, §5): decrypts, checks magic, version and
   * tag, gunzips, decodes, and checks the content names this note and file.
   */
  async readRevision(noteId: string, filename: string, data: Uint8Array): Promise<Revision> {
    const name = parseRevisionName(filename);
    if (!name || revisionFilename(name) !== filename) throw new RevisionReadError("undecodable", "not a revision file name");
    if (data.length > limits.revisionBytes) throw new RevisionReadError("undecryptable", "file larger than 256 MiB");
    let plain: Uint8Array;
    try {
      plain = await this.decrypter.decrypt(data);
    } catch (e) {
      throw new RevisionReadError("undecryptable", e instanceof Error ? e.message : String(e));
    }
    if (plain.length < headerSize) throw new RevisionReadError("corruptBody", "body shorter than its header");
    if (!magic.every((b, i) => plain[i] === b)) throw new RevisionReadError("corruptBody", "body does not start with SMPR");
    if (plain[4] !== 1) throw new RevisionReadError("corruptBody", `unsupported body version ${plain[4]}`);
    const tag = plain.subarray(5, headerSize);
    const gz = plain.subarray(headerSize);
    const message = concat([encoder.encode("sempere/1"), Uint8Array.of(0), encoder.encode(noteId), Uint8Array.of(0),
      encoder.encode(filename), Uint8Array.of(0), gz]);
    let ok = await crypto.subtle.verify("HMAC", this.secret, buf(tag), buf(message));
    if (!ok && this.previous) ok = await crypto.subtle.verify("HMAC", this.previous, buf(tag), buf(message));
    if (!ok) throw new RevisionReadError("tagMismatch", "authentication tag does not match (file altered, moved or renamed)");
    let json: unknown;
    try {
      const text = new TextDecoder("utf-8", { fatal: true }).decode(await gunzip(gz));
      json = JSON.parse(text);
    } catch (e) {
      throw new RevisionReadError("corruptBody", e instanceof Error ? e.message : String(e));
    }
    let rev: Revision;
    try {
      rev = decodeRevision(json);
    } catch (e) {
      throw new RevisionReadError("undecodable", e instanceof Error ? e.message : String(e));
    }
    if (rev.noteId !== noteId || rev.hlc !== name.hlc || rev.device !== name.device || rev.seq !== name.seq
      || rev.body.type !== name.kind) {
      throw new RevisionReadError("undecodable", `content is ${rev.noteId}/${rev.hlc}-${rev.device}-${rev.seq}.${rev.body.type}`);
    }
    return rev;
  }
}

function hex(b: Uint8Array): string {
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

async function decryptSecret(decrypter: Decrypter, armored: string): Promise<Uint8Array> {
  let bytes: Uint8Array;
  try {
    bytes = await decrypter.decrypt(armor.decode(armored));
  } catch (e) {
    throw new VaultError("wrongKey", `this key does not open the vault (${e instanceof Error ? e.message : String(e)})`);
  }
  if (bytes.length !== 32) throw new VaultError("invalidVaultSecret", "the vault secret is not 32 bytes");
  return bytes;
}

/** True for JSON objects; re-exported for the sources. */
export { isObject };
