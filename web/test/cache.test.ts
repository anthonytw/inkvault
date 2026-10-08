// The ciphertext cache (docs/web-viewer.md "Opening fast"): write-once paths
// only, LRU within a size bound, eviction of files gone from the listing, a
// failing cached copy dropped and fetched again, and the IndexedDB store.

import { IDBFactory } from "fake-indexeddb";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { CachingSource, FileCache, IndexedDBFileStore, MemoryFileStore, isCacheablePath } from "../src/vault/cache.ts";
import { loadNote } from "../src/vault/library.ts";
import { type VaultSource } from "../src/vault/source.ts";
import { NodeDirSource, fixtures, unlockFixture } from "./support.ts";

const lecture = "11111111-1111-4111-8111-111111111111";
const blobName = "a".repeat(64);

/** Counts what reaches the network. */
export class CountingSource implements VaultSource {
  readonly reads: string[] = [];
  readonly label: string;
  constructor(readonly inner: VaultSource) {
    this.label = inner.label;
  }
  read(path: string, max: number) {
    this.reads.push(path);
    return this.inner.read(path, max);
  }
  listNotes() {
    return this.inner.listNotes();
  }
  listRevisions(id: string) {
    return this.inner.listRevisions(id);
  }
}

describe("ciphertext cache", () => {
  it("caches only write-once vault files", () => {
    expect(isCacheablePath(`notes/${lecture}/17911308010000000-a1b2c3d4-1.delta.age`)).toBe(true);
    expect(isCacheablePath(`notes/${lecture}/att/${blobName}.image.age`)).toBe(true);
    for (const p of ["vault.json", "rewrap-journal.json", "sempere-index.json", "sempere-summaries.sealed",
      `notes/${lecture}/notes.txt`, "notes/7E57C0DE-0000-4000-8000-000000000001/17911308010000000-a1b2c3d4-1.delta.age",
      `notes/${lecture}/att/x.image.age`, `notes/${lecture}/att/${blobName}.image.age/x`, "inbox/x.capture.age"]) {
      expect(isCacheablePath(p), p).toBe(false);
    }
  });

  it("evicts least recently used files beyond its bound and skips files over the entry limit", async () => {
    let clock = 0;
    const cache = new FileCache(new MemoryFileStore(), { maxBytes: 300, maxEntryBytes: 150 }, () => ++clock);
    await cache.put("a", new Uint8Array(100));
    await cache.put("b", new Uint8Array(100));
    await cache.put("c", new Uint8Array(100));
    expect(await cache.get("a")).toBeDefined();   // a is now the most recent
    await cache.put("d", new Uint8Array(100));     // over 300: b goes
    expect(await cache.keys("")).toEqual(["a", "c", "d"]);
    await cache.put("big", new Uint8Array(151));
    expect(await cache.get("big")).toBeUndefined();
    expect(await cache.size()).toEqual({ files: 3, bytes: 300 });
    await cache.clear();
    expect(await cache.size()).toEqual({ files: 0, bytes: 0 });
  });

  it("serves a second read from the cache and drops a file that fails to verify", async () => {
    const dir = join(fixtures, "sample.sempere");
    const { vault } = await unlockFixture(dir);
    const net = new CountingSource(new NodeDirSource(dir));
    const store = new MemoryFileStore();
    const src = new CachingSource(net, new FileCache(store), "test\nvault");
    const first = await loadNote(src, vault, lecture);
    expect(first.failures).toEqual([]);
    const fetched = net.reads.length;
    expect(fetched).toBe(5);
    expect((await loadNote(src, vault, lecture)).state).toEqual(first.state);
    expect(net.reads.length).toBe(fetched);   // nothing downloaded again

    // A damaged cached copy is evicted and fetched again: the note still reads cleanly.
    const key = [...store.files.keys()][0] ?? "";
    const bad = store.files.get(key)?.bytes.slice() ?? new Uint8Array();
    bad[bad.length - 1] = (bad[bad.length - 1] ?? 0) ^ 1;
    store.files.set(key, { bytes: bad, used: 0 });
    const again = await loadNote(src, vault, lecture);
    expect(again.failures).toEqual([]);
    expect(net.reads.length).toBe(fetched + 1);
  });

  it("evicts what the listing no longer has", async () => {
    const store = new MemoryFileStore();
    const cache = new FileCache(store);
    const src = new CachingSource(new NodeDirSource(join(fixtures, "sample.sempere")), cache, "ns");
    const other = "22222222-2222-4222-8222-222222222222";
    for (const p of [`notes/${lecture}/17911308010000000-a1b2c3d4-1.delta.age`, `notes/${lecture}/17911308020000000-99ee00ff-1.delta.age`,
      `notes/${other}/17911308060000000-a1b2c3d4-1.delta.age`, `notes/${other}/att/${blobName}.image.age`]) {
      await cache.put(`ns\n${p}`, new Uint8Array([1]));
    }
    await cache.put(`another vault\nnotes/${other}/17911308060000000-a1b2c3d4-1.delta.age`, new Uint8Array([1]));
    // The second revision was compacted away and the other note deleted.
    expect(await src.retain(new Map([[lecture, ["17911308010000000-a1b2c3d4-1.delta.age"]]]))).toBe(3);
    expect(await cache.keys("")).toEqual([`ns\nnotes/${lecture}/17911308010000000-a1b2c3d4-1.delta.age`,
      `another vault\nnotes/${other}/17911308060000000-a1b2c3d4-1.delta.age`]);
  });

  it("keeps a streamed file only once it was read to the end", async () => {
    const cache = new FileCache(new MemoryFileStore());
    const path = `notes/${lecture}/att/${blobName}.image.age`;
    const inner: VaultSource = {
      label: "x", listNotes: () => Promise.resolve([]), listRevisions: () => Promise.resolve([]),
      read: () => Promise.resolve(new Uint8Array([1, 2, 3])),
    };
    const src = new CachingSource(inner, cache, "ns");
    await (await src.stream(path, 10)).cancel();
    expect(await cache.keys("")).toEqual([]);
    expect(new Uint8Array(await new Response(await src.stream(path, 10)).arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
    expect(await cache.keys("")).toEqual([`ns\n${path}`]);
    expect(new Uint8Array(await new Response(await src.stream(path, 10)).arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
    expect(cache.stats).toEqual({ hits: 1, misses: 2 });
  });

  it("stores ciphertext in IndexedDB across tabs", async () => {
    const factory = new IDBFactory();
    const a = await IndexedDBFileStore.open(factory);
    await a.put("k1", new Uint8Array([1, 2]), 10);
    await a.put("k2", new Uint8Array([3]), 20);
    await a.touch("k1", 30);
    await a.delete(["k2"]);
    a.close();
    const b = await IndexedDBFileStore.open(factory);
    expect(await b.entries()).toEqual([{ key: "k1", size: 2, used: 30 }]);
    expect(await b.get("k1")).toEqual(new Uint8Array([1, 2]));
    expect(await b.get("k2")).toBeUndefined();
    const cache = new FileCache(b);
    expect(await cache.size()).toEqual({ files: 1, bytes: 2 });
    await cache.clear();
    expect(await b.entries()).toEqual([]);
    b.close();
    await IndexedDBFileStore.destroy(factory);
  });
});
