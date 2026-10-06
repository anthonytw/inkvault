// Writes web/test/fixtures/render.sempere: a vault encrypted to the throwaway
// test recipient of Tests/SempereTests/Fixtures/sample.key, whose notes
// exercise the renderer (every paper kind, every tool, transforms, an infinite
// page) and the merge (two devices, a snapshot, tags, removals, an orphan,
// attachments, unknown fields). Synthetic content only.
//
// Run: npm run fixture (from web/). age encryption is randomized, so the
// ciphertext changes on every run; the decrypted JSON does not. Then run
// scripts/golden.sh to export the Swift CLI's view of it.

import { Encrypter, armor, identityToRecipient } from "age-encryption";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const web = join(import.meta.dirname, "..");
const keyFile = join(web, "..", "Tests", "SempereTests", "Fixtures", "sample.key");
const out = join(web, "test", "fixtures", "render.sempere");

const identity = readFileSync(keyFile, "utf8").split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-"));
if (!identity) throw new Error("no identity in sample.key");
const recipient = await identityToRecipient(identity);

// A fixed secret: the fixture is test-only, and a stable secret keeps the tags stable.
const secret = new Uint8Array(32).map((_, i) => (i * 7 + 3) & 0xff);

async function encrypt(data: Uint8Array): Promise<Uint8Array> {
  const e = new Encrypter();
  e.addRecipient(recipient);
  return e.encrypt(data);
}

async function gzip(data: Uint8Array): Promise<Uint8Array> {
  const s = new Blob([data as Uint8Array<ArrayBuffer>]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(s).arrayBuffer());
}

const enc = new TextEncoder();

async function frame(json: unknown, noteId: string, filename: string): Promise<Uint8Array> {
  const gz = await gzip(enc.encode(JSON.stringify(json)));
  const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const parts = [enc.encode("sempere/1"), Uint8Array.of(0), enc.encode(noteId), Uint8Array.of(0),
    enc.encode(filename), Uint8Array.of(0), gz];
  const msg = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    msg.set(p, at);
    at += p.length;
  }
  const tag = new Uint8Array(await crypto.subtle.sign("HMAC", key, msg));
  const body = new Uint8Array(37 + gz.length);
  body.set(enc.encode("SMPR"), 0);
  body[4] = 1;
  body.set(tag, 5);
  body.set(gz, 37);
  return body;
}

const devA = "a1b2c3d4", devB = "99ee00ff";
const t0 = Date.UTC(2026, 9, 4, 16, 20, 0);

function hlc(offsetSeconds: number, counter = 0): string {
  return String(t0 + offsetSeconds * 1000).padStart(13, "0") + String(counter).padStart(4, "0");
}

function wall(offsetSeconds: number): string {
  return new Date(t0 + offsetSeconds * 1000).toISOString();
}

type Json = Record<string, unknown>;

async function write(noteId: string, rev: Json): Promise<void> {
  const name = `${rev.hlc as string}-${rev.device as string}-${rev.seq as number}.${rev.type as string}.age`;
  const dir = join(out, "notes", noteId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), await encrypt(await frame(rev, noteId, name)));
}

function delta(noteId: string, device: string, seq: number, at: number, ops: Json[]): Json {
  return { type: "delta", noteId, device, seq, hlc: hlc(at), wall: wall(at), app: "sempere-web-fixture/1", ops };
}

function id(n: number): string {
  return `f1c70000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
}

/** A wavy line of control points. */
function wave(x0: number, y0: number, len: number, opts: { w?: number; o?: number; n?: number; amp?: number } = {}): number[][] {
  const n = opts.n ?? 24;
  return Array.from({ length: n }, (_, i) => {
    const x = x0 + (len * i) / (n - 1);
    const y = y0 + Math.round(Math.sin(i / 2.5) * (opts.amp ?? 8) * 1000) / 1000;
    const w = opts.w ?? 2 + (i % 5) * 0.5;
    return [Math.round(x * 1000) / 1000, y, i * 0.01, w, w, opts.o ?? 1, 0.5, 0.3, 1.2];
  });
}

function stroke(n: number, tool: string, color: string, width: number, points: number[][], extra: Json = {}): Json {
  return { id: id(n), ink: { tool, color, width }, points, ...extra };
}

const letter = { width: 612, height: 792, infinite: false };

rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, "notes"), { recursive: true });

// --- Note 1: every paper kind, one page each, and every tool.
{
  const note = "33333333-3333-4333-8333-333333333333";
  const papers: Json[] = [
    { kind: "blank", spacing: 24, background: "#FFF8E1FF", lineColor: "#D0D8E8FF" },
    { kind: "ruled", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF", marginLeft: 60, marginTop: 50 },
    { kind: "marginRuled", spacing: 20, background: "#FFFFFFFF", lineColor: "#C0C8D8FF" },
    { kind: "grid", spacing: 18, background: "#FFFFFF", lineColor: "#D0D8E880", lineWidth: 0.25 },
    { kind: "dot", spacing: 18, background: "#FFFFFFFF", lineColor: "#9AA3B5FF", dotRadius: 1.2 },
    { kind: "isoDot", spacing: 20, background: "#FFFFFFFF", lineColor: "#9AA3B5FF" },
    { kind: "isoGrid", spacing: 20, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" },
    { kind: "cornell", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF", cueWidth: 140, summaryHeight: 100 },
    { kind: "staff", spacing: 24, background: "#FFFFFFFF", lineColor: "#9AA3B5FF", staffSpacing: 8, staffGap: 36 },
    // Out of range and an unknown kind: readers clamp, and draw an unknown kind as blank (§5.4.2).
    { kind: "ruled", spacing: 24, background: "#1C1C1EFF", lineColor: "#444444FF", lineWidth: 9, marginLeft: 900 },
    { kind: "hexagons", spacing: 30, background: "#E8F5E9FF", lineColor: "#D0D8E8FF", hexSize: 12 },
    { kind: "grid", spacing: 2, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" },
  ];
  const ops: Json[] = [
    { op: "setMeta", field: "title", value: "Papers & tools <test>" },
    { op: "setMeta", field: "paper", value: { kind: "ruled", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" } },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "setMeta", field: "notebook", value: "Fixtures/Rendering" },
  ];
  papers.forEach((paper, i) => {
    const pid = id(0x100 + i);
    ops.push({ op: "addPage", page: { id: pid, order: `a${i.toString(36)}`, strokes: [] } });
    ops.push({ op: "setPagePaper", pageId: pid, paper });
  });
  const tools = ["pen", "pencil", "marker", "monoline", "fountainPen", "watercolor", "crayon", "brush"];
  tools.forEach((tool, i) => {
    ops.push({ op: "addStroke", page: id(0x100), stroke: stroke(0x200 + i, tool, i % 2 ? "#1A1A1AFF" : "#2E5BFFCC", 3, wave(60, 80 + i * 60, 480, { o: i === 1 ? 0.6 : 1 })) });
  });
  // Shapes that stress the outline: a dot, a monoline dot, repeated points,
  // zero widths (fallback to the ink width), a sharp zigzag, transforms.
  ops.push({ op: "addStroke", page: id(0x101), stroke: stroke(0x210, "pen", "#000000FF", 4, [[300, 300, 0, 6, 6, 1, 0, 0, 1.5]]) });
  ops.push({ op: "addStroke", page: id(0x101), stroke: stroke(0x211, "monoline", "#FF0000FF", 5, [[320, 300, 0, 2, 2, 1, 0, 0, 1.5], [320, 300, 0.1, 2, 2, 1, 0, 0, 1.5]]) });
  ops.push({ op: "addStroke", page: id(0x101), stroke: stroke(0x212, "pen", "#006400FF", 3, [[100, 400, 0, 0, 0, 1, 0, 0, 1], [100, 400, 0, 0, 0, 1, 0, 0, 1], [200, 450, 0, 0, 0, 1, 0, 0, 1], [300, 400, 0, 4, 4, 0.5, 0, 0, 1]]) });
  ops.push({ op: "addStroke", page: id(0x101), stroke: stroke(0x213, "pen", "#800080FF", 2, [[80, 600, 0, 3, 3, 1, 0, 0, 1], [120, 500, 0, 3, 3, 1, 0, 0, 1], [160, 600, 0, 3, 3, 1, 0, 0, 1], [200, 500, 0, 3, 3, 1, 0, 0, 1], [240, 600, 0, 3, 3, 1, 0, 0, 1]]) });
  ops.push({ op: "addStroke", page: id(0x102), stroke: stroke(0x214, "pen", "#000000FF", 2, wave(100, 200, 200), { transform: [1.5, 0.5, -0.5, 1.5, 40, 30] }) });
  ops.push({ op: "addStroke", page: id(0x102), stroke: stroke(0x215, "monoline", "#000000FF", 2, wave(100, 500, 200), { transform: [0.5, 0, 0, 0.5, 100, 100] }) });
  ops.push({ op: "addStroke", page: id(0x103), stroke: stroke(0x216, "marker", "#FFEB3B80", 12, wave(60, 300, 480, { w: 14, n: 40, amp: 2 })) });
  // A stroke with an unknown future field and a recording link (§7, §5.6).
  ops.push({ op: "addStroke", page: id(0x104), stroke: stroke(0x217, "pen", "#000000FF", 2, wave(60, 300, 300), { pressureCurve: [0, 1], rec: { id: id(0x900), at: 1.25 } }) });
  await write(note, delta(note, devA, 1, 1, ops));
}

// --- Note 2: an infinite page with ink far below its stored height.
{
  const note = "44444444-4444-4444-8444-444444444444";
  const pid = id(0x300);
  await write(note, delta(note, devA, 1, 2, [
    { op: "setMeta", field: "title", value: "Infinite cornell" },
    { op: "setMeta", field: "paper", value: { kind: "cornell", spacing: 24, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" } },
    { op: "setMeta", field: "pageSize", value: { width: 600, height: 900, infinite: true, breakHeight: 700 } },
    { op: "addPage", page: { id: pid, order: "a0", strokes: [] } },
    { op: "addStroke", page: pid, stroke: stroke(0x301, "pen", "#000000FF", 2, wave(200, 100, 300)) },
    { op: "addStroke", page: pid, stroke: stroke(0x302, "pen", "#B00020FF", 2, wave(200, 2500, 300)) },
  ]));
  // A second infinite page with no breakHeight and dot paper on the page itself.
  const pid2 = id(0x303);
  await write(note, delta(note, devB, 1, 3, [
    { op: "addPage", page: { id: pid2, order: "a1", strokes: [] } },
    { op: "setPagePaper", pageId: pid2, paper: { kind: "dot", spacing: 24, background: "#FFFFFFFF", lineColor: "#9AA3B5FF", marginLeft: 50 } },
    { op: "addStroke", page: pid2, stroke: stroke(0x304, "pencil", "#333333FF", 1.5, wave(50, 1800, 500)) },
  ]));
}

// --- Note 3: merging. Two devices, a snapshot, removals, page order,
// recognition, tags (legacy and per-tag), an orphan, attachments.
{
  const note = "55555555-5555-4555-8555-555555555555";
  const p1 = id(0x400), p2 = id(0x401), p3 = id(0x402), ghost = id(0x4ff);
  const a1 = delta(note, devA, 1, 10, [
    { op: "setMeta", field: "title", value: "Merge lab" },
    { op: "setMeta", field: "tags", value: ["Physics", "fall  term", "physics"] },
    { op: "setMeta", field: "paper", value: { kind: "grid", spacing: 20, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" } },
    { op: "setMeta", field: "pageSize", value: letter },
    { op: "addPage", page: { id: p1, order: "a0", strokes: [] } },
    { op: "addPage", page: { id: p2, order: "a1", strokes: [] } },
    { op: "addStroke", page: p1, stroke: stroke(0x410, "pen", "#000000FF", 2, wave(60, 100, 400)) },
    { op: "addStroke", page: p1, stroke: stroke(0x411, "pen", "#000000FF", 2, wave(60, 200, 400)) },
    { op: "addStroke", page: p2, stroke: stroke(0x412, "pen", "#000000FF", 2, wave(60, 100, 400)) },
  ]);
  const b1 = delta(note, devB, 1, 11, [
    { op: "addTag", tag: "  Lab   notes " },
    { op: "addPage", page: { id: p3, order: "a0V", strokes: [] } },
    { op: "addStroke", page: p3, stroke: stroke(0x413, "marker", "#4CAF5080", 10, wave(60, 300, 400, { w: 10 })) },
    { op: "setPageRecognition", pageId: p1, recognition: { engine: "vision-26.7", text: "wave one\nwave two", words: [{ t: "wave", box: [60, 90, 40, 20] }], basis: "0123456789abcdef0123456789abcdef" } },
    { op: "setMeta", field: "favorite", value: true },
  ]);
  const a2 = delta(note, devA, 2, 12, [
    { op: "removeStroke", page: p1, strokeId: id(0x411) },
    { op: "setPageOrder", pageId: p2, order: "Z" },
    { op: "setMeta", field: "notebook", value: " School // Physics " },
  ]);
  // A snapshot on B covering A1, A2 and B1, written as Swift's makeSnapshot would.
  const snapState = {
    deleted: false,
    meta: {
      title: "Merge lab", tags: ["Physics", "fall term", "Lab notes"], notebook: " School // Physics ", favorite: true,
      created: wall(10), paper: { kind: "grid", spacing: 20, background: "#FFFFFFFF", lineColor: "#D0D8E8FF" }, pageSize: letter,
    },
    pages: [
      { id: p2, order: "Z", orderClock: `${hlc(12)}-${devA}`, origin: `${hlc(10)}-${devA}-1-5`, strokes: [
        { ...stroke(0x412, "pen", "#000000FF", 2, wave(60, 100, 400)), origin: `${hlc(10)}-${devA}-1-8` }] },
      { id: p1, order: "a0", orderClock: `${hlc(10)}-${devA}`, origin: `${hlc(10)}-${devA}-1-4`,
        recognition: { engine: "vision-26.7", text: "wave one\nwave two", words: [{ t: "wave", box: [60, 90, 40, 20] }], basis: "0123456789abcdef0123456789abcdef" },
        recognitionClock: `${hlc(11)}-${devB}`, strokes: [
          { ...stroke(0x410, "pen", "#000000FF", 2, wave(60, 100, 400)), origin: `${hlc(10)}-${devA}-1-6` }] },
      { id: p3, order: "a0V", orderClock: `${hlc(11)}-${devB}`, origin: `${hlc(11)}-${devB}-1-1`, futurePageField: { x: 1 }, strokes: [
        { ...stroke(0x413, "marker", "#4CAF5080", 10, wave(60, 300, 400, { w: 10 })), origin: `${hlc(11)}-${devB}-1-2` }] },
    ],
    clocks: { title: `${hlc(10)}-${devA}`, notebook: `${hlc(12)}-${devA}`, favorite: `${hlc(11)}-${devB}`, paper: `${hlc(10)}-${devA}`, pageSize: `${hlc(10)}-${devA}`, deleted: "00000000000000000-00000000" },
    tagSet: {
      instances: [{ tag: "Physics", origin: `${hlc(10)}-${devA}-0-0` }, { tag: "fall term", origin: `${hlc(10)}-${devA}-0-1` },
        { tag: "Lab notes", origin: `${hlc(11)}-${devB}-1-0` }],
      removed: [],
      legacy: { tags: ["Physics", "fall  term", "physics"], clock: `${hlc(10)}-${devA}` },
    },
  };
  const b2 = { type: "snapshot", noteId: note, device: devB, seq: 2, hlc: hlc(13), wall: wall(13), app: "sempere-web-fixture/1",
    included: { [devA]: { upTo: 2, extra: [] }, [devB]: { upTo: 2, extra: [] } }, state: snapState };
  // After the snapshot: A removes a tag it saw, adds one, removes page p3,
  // deletes and restores the note; B (concurrently) adds a stroke to a page
  // nobody has seen (an orphan), an item and a recording.
  const a3 = delta(note, devA, 3, 14, [
    { op: "removeTag", tag: "FALL TERM", observed: [`${hlc(10)}-${devA}-0-1`] },
    { op: "addTag", tag: "Optics" },
    { op: "removePage", pageId: p3 },
    { op: "deleteNote" },
    { op: "restoreNote" },
    { op: "addStroke", page: p1, stroke: stroke(0x414, "fountainPen", "#0D47A1FF", 2.5, wave(60, 400, 450)) },
  ]);
  const b3 = delta(note, devB, 3, 14, [
    { op: "addStroke", page: ghost, stroke: stroke(0x415, "pen", "#000000FF", 2, wave(60, 500, 400)) },
    { op: "addItem", page: p1, item: { id: id(0x800), kind: "text", layer: 100, frame: [72, 600, 300, 40], z: "a0",
      text: { font: "sans", size: 14, color: "#1A1A1AFF", runs: [{ t: "Typed text", b: true }] } } },
    { op: "addRecording", recording: { id: id(0x900), blob: { sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", size: 1000, type: "audio/mp4" },
      started: wall(14), duration: 12.5 } },
    { op: "setMeta", field: "title", value: "Merge lab (B)" },
  ]);
  for (const r of [a1, b1, a2, b2, a3, b3]) await write(note, r);
}

// --- Note 4: deleted, in a notebook, with a page that has no strokes.
{
  const note = "66666666-6666-4666-8666-666666666666";
  await write(note, delta(note, devB, 1, 20, [
    { op: "setMeta", field: "title", value: "Gone" },
    { op: "setMeta", field: "notebook", value: "Fixtures" },
    { op: "setMeta", field: "pageSize", value: { width: 595, height: 842, infinite: false } },
    { op: "addPage", page: { id: id(0x600), order: "a0", strokes: [] } },
    { op: "deleteNote" },
  ]));
}

const manifest = {
  format: "sempere/1",
  vaultId: "5a3b1e00-1000-4000-8000-000000000002",
  created: wall(0),
  recipients: [{ key: recipient, label: "TEST-ONLY fixture key", added: wall(0) }],
  vaultSecret: armor.encode(await encrypt(secret)),
  features: ["attachments"],
};
writeFileSync(join(out, "vault.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log(`wrote ${out}`);
