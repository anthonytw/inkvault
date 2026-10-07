// Cross-check of placed items (format.md §8.2.3, §8.5) against the Swift
// CLI's SVG export (test/golden, `--pdf-renderer none`). The glyphs differ
// by design (the CLI embeds its own fonts, the viewer uses the browser's),
// so the `items` group is compared structurally: background fills,
// placeholders, each image's clip and matrix (blobs read and checked by the
// viewer's own reader), and each text line's baseline, size, characters and
// direction (and its x where it does not depend on glyph widths), plus the
// rotation of each text box. PDF pages are placeholders in the CLI export
// without Poppler; the viewer draws them with pdf.js, so only their rotated
// frames are compared here.

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { loadNote } from "../src/vault/library.ts";
import { NoteBlobs } from "../src/vault/blobs.ts";
import { UnlockedVault, parseManifest } from "../src/vault/vault.ts";
import { PreparedPage } from "../src/render/page.ts";
import { resolveItems, textTransform } from "../src/render/itemsvg.ts";
import { imageInfo } from "../src/render/images.ts";
import { type Affine, identity, imageTransform, pointsAttr, svgMatrix } from "../src/render/items.ts";
import { fmt, paint, paintHex } from "../src/render/primitives.ts";
import { lineAnchor } from "../src/render/text.ts";
import { pageExtent } from "../src/ui/noteview.ts";
import { NodeDirSource, fixtures, golden, sampleIdentity, webFixtures } from "./support.ts";

interface Structure {
  fills: string[];
  placeholders: string[];
  images: { clip: string; matrix: number[] }[];
  lines: { y: string; size: string; text: string; rtl: boolean; x?: string }[];
  transforms: string[];
}

function attr(line: string, name: string): string | undefined {
  return new RegExp(`(?:^|\\s)${name}="([^"]*)"`).exec(line)?.[1];
}

function unescape(s: string): string {
  return s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&amp;/g, "&");
}

/** The structure of the Swift export's `<g id="items">`, given the page's paper colour. */
function parseGolden(svg: string, paper: string): Structure {
  const out: Structure = { fills: [], placeholders: [], images: [], lines: [], transforms: [] };
  const m = /<g id="items">\n([\s\S]*?)<\/g>\n<g id="strokes">/.exec(svg);
  if (!m) return out;
  const clips = new Map<string, string>();
  for (const c of (m[1] ?? "").matchAll(/<clipPath id="([^"]+)"><polygon points="([^"]+)"\/><\/clipPath>/g)) clips.set(c[1] ?? "", c[2] ?? "");
  for (const line of (m[1] ?? "").split("\n")) {
    if (line.startsWith("<path ") && attr(line, "stroke") === "#9aa0a6") {
      const d = attr(line, "d") ?? "";
      out.placeholders.push(d.replace(/Z$/, "").split(/[ML]/).filter((p) => p).map((p) => p.replace(" ", ",")).join(" "));
    } else if (line.startsWith("<path ") && !attr(line, "stroke") && attr(line, "fill") === paper) {
      out.fills.push(attr(line, "d") ?? "");
    } else if (line.startsWith("<g clip-path=")) {
      const id = /url\(#([^)]+)\)/.exec(line)?.[1] ?? "";
      const matrix = (/matrix\(([^)]+)\)/.exec(line)?.[1] ?? "").split(" ").map(Number);
      out.images.push({ clip: clips.get(id) ?? "?", matrix });
    } else if (line.startsWith("<g transform=")) {
      out.transforms.push(attr(line, "transform") ?? "");
    } else if (line.startsWith("<text x=")) {
      const text = unescape(/>([^<]*)<\/text>$/.exec(line)?.[1] ?? "");
      out.lines.push({ y: attr(line, "y") ?? "", size: attr(line, "font-size") ?? "", text, rtl: attr(line, "direction") === "rtl", x: attr(line, "x") ?? "" });
    }
  }
  return out;
}

function matrixOf(m: Affine): number[] {
  return [m.a, m.b, m.c, m.d, m.tx, m.ty];
}

const dir = join(webFixtures, "render.sempere");

describe.runIf(existsSync(dir))("items cross-check", async () => {
  const source = new NodeDirSource(dir);
  const vault = await UnlockedVault.unlock(parseManifest(await source.read("vault.json", 1 << 24)), sampleIdentity());
  const ids = (await source.listNotes()).filter((id) => id.startsWith("7") || id.startsWith("8"));

  it("has notes with items", () => {
    expect(ids.length).toBeGreaterThanOrEqual(2);
  });

  for (const id of ids) {
    it(`places the items of ${id} like the Swift CLI`, async () => {
      const note = await loadNote(source, vault, id);
      if (!note.state) throw new Error(note.error);
      const state = note.state;
      const blobs = new NoteBlobs(source, vault, id);
      const files = readdirSync(join(golden, "render", id)).sort();
      for (const [i, page] of state.pages.entries()) {
        const prepared = new PreparedPage(page, state.meta);
        const want = parseGolden(readFileSync(join(golden, "render", id, files[i] ?? ""), "utf8"), paintHex(paint(prepared.drawnPaper.background)));
        const got: Structure = { fills: [], placeholders: [], images: [], lines: [], transforms: [] };
        for (const r of resolveItems(prepared)) {
          if (r.fill) got.fills.push(r.fill.attrs.find(([k]) => k === "d")?.[1] ?? "");
          const d = r.draw;
          const corners = pointsAttr(d.it.corners);
          switch (d.kind) {
            case "placeholder":
              got.placeholders.push(corners);
              break;
            case "pdf":
              // Goldens are made with --pdf-renderer none: a PDF page is a placeholder there, and an
              // equation's render falls back to its source as text (§8.2.7), drawn like a text box.
              if (!d.math) {
                got.placeholders.push(corners);
                break;
              }
              for (const line of d.math.layout.lines) {
                if (line.text.trim().length === 0) continue;
                got.lines.push({ y: fmt(line.baseline), size: fmt(line.size), text: line.text, rtl: line.rtl,
                  x: fmt(lineAnchor(d.math.content.align, line.rtl, d.it.frame).x) });
              }
              break;
            case "image": {
              try {
                const bytes = new Uint8Array(await (await blobs.get(d.ref)).arrayBuffer());
                const info = imageInfo(bytes);
                const m = imageTransform(d.it, info.width, info.height);
                if (typeof m === "string") throw new Error(m);
                got.images.push({ clip: corners, matrix: matrixOf(m) });
              } catch {
                got.placeholders.push(corners);
              }
              break;
            }
            case "text": {
              const m = textTransform(d.it);
              if (m !== identity) got.transforms.push(svgMatrix(m));
              for (const line of d.layout.lines) {
                if (line.text.trim().length === 0) continue;
                const a = lineAnchor(d.content.align, line.rtl, d.it.frame);
                const l: Structure["lines"][number] = { y: fmt(line.baseline), size: fmt(line.size), text: line.text, rtl: line.rtl };
                if (a.anchor === "start" && !line.rtl) l.x = fmt(a.x);
                got.lines.push(l);
              }
              break;
            }
          }
        }
        expect(got.fills).toEqual(want.fills);
        expect(got.placeholders).toEqual(want.placeholders);
        expect(got.transforms).toEqual(want.transforms);
        expect(got.images.map((x) => x.clip)).toEqual(want.images.map((x) => x.clip));
        got.images.forEach((img, k) => {
          const w = want.images[k]?.matrix ?? [];
          img.matrix.forEach((v, j) => expect(v).toBeCloseTo(w[j] ?? NaN, 3));
        });
        expect(got.lines.map((l) => ({ ...l, x: l.x ?? "" }))).toEqual(want.lines.map((l, k) => ({ ...l, x: got.lines[k]?.x === undefined ? "" : l.x })));
      }
    });
  }
});

describe("page layout without outlining", () => {
  it("gives every fixture page the height PreparedPage draws", async () => {
    for (const dir of [join(webFixtures, "render.sempere"), join(fixtures, "sample.sempere")]) {
      const source = new NodeDirSource(dir);
      const vault = await UnlockedVault.unlock(parseManifest(await source.read("vault.json", 1 << 24)), sampleIdentity());
      for (const id of await source.listNotes()) {
        const state = (await loadNote(source, vault, id)).state;
        if (!state) continue;
        for (const page of state.pages) expect(pageExtent(page, state)).toBe(new PreparedPage(page, state.meta).extent);
      }
    }
  });

  it("grows a finite page by ink and items centred below it, as PreparedPage does", async () => {
    const source = new NodeDirSource(join(webFixtures, "render.sempere"));
    const vault = await UnlockedVault.unlock(parseManifest(await source.read("vault.json", 1 << 24)), sampleIdentity());
    const state = (await loadNote(source, vault, "77777777-7777-4777-8777-777777777777")).state;
    if (!state) throw new Error("fixture");
    const page = state.pages[0];
    if (!page) throw new Error("fixture");
    const low = { ...page, items: [...page.items, { id: "ffffffff-0000-4000-8000-000000000000", kind: "sticker", frame: [10, 900, 50, 50], z: "zz" }] };
    expect(pageExtent(low, state)).toBe(950);
    expect(new PreparedPage(low, state.meta).extent).toBe(950);
  });
});
