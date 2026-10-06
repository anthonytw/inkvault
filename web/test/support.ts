// Test helpers: a vault source over a local directory (Node only).

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { isLowercaseUUID } from "../src/format/json.ts";
import { SourceError, type VaultSource, isRevisionFile } from "../src/vault/source.ts";

export const repo = join(import.meta.dirname, "..", "..");
export const fixtures = join(repo, "Tests", "SempereTests", "Fixtures");
export const webFixtures = join(import.meta.dirname, "fixtures");
export const golden = join(import.meta.dirname, "golden");

export function sampleIdentity(): string {
  const text = readFileSync(join(fixtures, "sample.key"), "utf8");
  const line = text.split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-"));
  if (!line) throw new Error("no key in sample.key");
  return line;
}

export class NodeDirSource implements VaultSource {
  constructor(readonly root: string, readonly label = root) {}

  read(path: string, maxBytes: number): Promise<Uint8Array> {
    const p = join(this.root, path);
    try {
      if (statSync(p).size > maxBytes) return Promise.reject(new SourceError("too large"));
      return Promise.resolve(new Uint8Array(readFileSync(p)));
    } catch {
      return Promise.reject(new SourceError(`${path} not found`, true));
    }
  }

  listNotes(): Promise<string[]> {
    return Promise.resolve(readdirSync(join(this.root, "notes")).filter(isLowercaseUUID).sort());
  }

  listRevisions(id: string): Promise<string[]> {
    return Promise.resolve(readdirSync(join(this.root, "notes", id)).filter(isRevisionFile).sort());
  }
}
