// Seeded mutation fuzzing of the parsers that see untrusted bytes (format.md
// §9): every failure must be the reader's typed error, never another
// exception, a hang or an unbounded allocation. Quick mode (about a second);
// SEMPERE_FUZZ_LONG=1 runs longer, as in the Swift tests.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DecodeError } from "../src/format/json.ts";
import { decodeRevision } from "../src/format/model.ts";
import { NoteLogError, reconstruct } from "../src/format/reducer.ts";
import { renderSVG } from "../src/render/page.ts";
import { RenderError } from "../src/render/primitives.ts";
import { SourceError, parseIndex, propfindNames } from "../src/vault/source.ts";
import { VaultError, parseManifest } from "../src/vault/vault.ts";
import { golden } from "./support.ts";

const iterations = process.env.SEMPERE_FUZZ_LONG ? 20_000 : 600;

/** xorshift32: deterministic per seed. */
function rng(seed: number): () => number {
  let x = seed >>> 0 || 1;
  return () => {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    return (x >>> 0) / 2 ** 32;
  };
}

const interesting: unknown[] = [null, true, false, 0, -1, 1.5, 1e308, -1e308, 2 ** 53, 2 ** 53 + 2, "", "x", "#GGGGGG",
  "2026-02-30T00:00:00Z", "00000000000000000", "ffffffff", "11111111-1111-4111-8111-111111111111", [], {}, [1, 2], { op: "x" }];

function mutate(v: unknown, r: () => number, depth = 0): unknown {
  const pick = <T>(a: readonly T[]): T => a[Math.floor(r() * a.length)] as T;
  if (depth > 0 && r() < 0.15) return pick(interesting);
  if (Array.isArray(v)) {
    const a: unknown[] = (v as unknown[]).map((e) => (r() < 0.2 ? mutate(e, r, depth + 1) : e));
    if (r() < 0.05) a.pop();
    if (r() < 0.05 && a.length) a.push(a[0]);
    return a;
  }
  if (v && typeof v === "object") {
    const o: Record<string, unknown> = { ...(v as Record<string, unknown>) };
    for (const k of Object.keys(o)) {
      if (r() < 0.05) delete o[k];
      else if (r() < 0.2) o[k] = mutate(o[k], r, depth + 1);
    }
    return o;
  }
  if (typeof v === "number") return r() < 0.5 ? v * (r() * 4 - 2) : pick(interesting);
  if (typeof v === "string") return r() < 0.5 ? v.slice(0, Math.floor(r() * v.length)) : pick(interesting);
  return pick(interesting);
}

/** Revisions in plain JSON, from the Swift CLI's state exports wrapped as snapshots. */
function seeds(): unknown[] {
  const ids = ["11111111-1111-4111-8111-111111111111", "55555555-5555-4555-8555-555555555555"];
  return ids.flatMap((id) => {
    const dir = id.startsWith("1") ? "sample" : "render";
    const state = JSON.parse(readFileSync(join(golden, dir, `${id}.json`), "utf8")) as unknown;
    return [{
      type: "snapshot", noteId: id, device: "a1b2c3d4", seq: 9, hlc: "17911308990000000", wall: "2026-10-04T16:30:00.000Z",
      app: "fuzz", included: { a1b2c3d4: { upTo: 8, extra: [] } }, state,
    }, {
      type: "delta", noteId: id, device: "99ee00ff", seq: 3, hlc: "17911308990000001", wall: "2026-10-04T16:30:00.000Z",
      app: "fuzz", ops: [{ op: "addTag", tag: "x" }, { op: "setMeta", field: "title", value: "t" },
        { op: "setPagePaper", pageId: "f1c70000-0000-4000-8000-000000000001", paper: { kind: "dot", spacing: 4, background: "#FFF", lineColor: "#000" } },
        { op: "removeTag", tag: "x", observed: ["17911308990000001-99ee00ff-0-0"] }],
    }];
  });
}

describe("fuzz", () => {
  it("decodes, merges and renders mutated revisions with typed errors only", () => {
    const base = seeds();
    const r = rng(0x5e3a);
    let decoded = 0;
    for (let i = 0; i < iterations; i++) {
      const v = mutate(base[i % base.length], r);
      try {
        const rev = decodeRevision(v);
        decoded++;
        const state = reconstruct([rev]);
        for (const p of state.pages.slice(0, 2)) {
          try {
            renderSVG(p, state.meta);
          } catch (e) {
            if (!(e instanceof RenderError)) throw e;
          }
        }
      } catch (e) {
        if (!(e instanceof DecodeError || e instanceof NoteLogError)) {
          throw new Error(`iteration ${i}: ${String(e)}\n${JSON.stringify(v).slice(0, 2000)}`, { cause: e });
        }
      }
    }
    expect(decoded).toBeGreaterThan(0);
  });

  it("parses mutated manifests, indexes and PROPFIND bodies with typed errors only", () => {
    const r = rng(0xbeef);
    const manifest = JSON.parse(readFileSync(join(golden, "..", "fixtures", "render.sempere", "vault.json"), "utf8")) as unknown;
    const index = { format: "sempere-index/1", notes: { "11111111-1111-4111-8111-111111111111": ["17911308010000000-a1b2c3d4-1.delta.age"] } };
    const enc = new TextEncoder();
    for (let i = 0; i < iterations; i++) {
      for (const [v, f, E] of [[manifest, parseManifest, VaultError], [index, parseIndex, SourceError]] as const) {
        const bytes = enc.encode(JSON.stringify(mutate(v, r)));
        if (r() < 0.2) bytes[Math.floor(r() * bytes.length)] = Math.floor(r() * 256);
        try {
          f(bytes);
        } catch (e) {
          if (!(e instanceof E)) throw e;
        }
      }
      const xml = `<d:multistatus><d:href>${"/a/%zz&#x110000;&amp;<b>".slice(0, Math.floor(r() * 24))}</d:href></d:multistatus>`;
      expect(Array.isArray(propfindNames(xml))).toBe(true);
    }
  });
});
