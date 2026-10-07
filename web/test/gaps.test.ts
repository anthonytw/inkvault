// The note registers `lang` and `markersBehindText` (format.md §5.4), PDF page
// text (`pageText`, §8.2.6) and the marker drawing order (§8.2.3), ported from
// Tests/SempereTests/NoteLanguageTests.swift and
// Tests/SempereRenderTests/MarkersBehindTextTests.swift.

import { describe, expect, it } from "vitest";
import { Budget } from "../src/format/attachments.ts";
import { type NoteState, type Op, decodeOp, validLanguage } from "../src/format/model.ts";
import { reconstruct } from "../src/format/reducer.ts";
import { PreparedPage, elementSpec, pageSVG } from "../src/render/page.ts";
import { pdfPageText, summarize } from "../src/vault/library.ts";
import { LogBuilder, devA, devB, devC, op, p1, snapshotParts, stroke } from "./builders.ts";

const setMeta = (field: string, value: unknown): Op =>
  decodeOp({ op: "setMeta", field, value }, "op", new Budget());

describe("lang and markersBehindText", () => {
  it("decodes, validates and merges last writer wins", () => {
    expect(validLanguage("en_US")).toBe("en-US");
    expect(validLanguage("en US")).toBeUndefined();
    expect(() => setMeta("lang", "en_US")).toThrow();
    expect(() => setMeta("markersBehindText", "yes")).toThrow();
    const log = new LogBuilder();
    const base = log.delta(devA, 0, [op.addPage(p1, "V")]);
    const es = log.delta(devA, 100, [setMeta("lang", "es-ES"), setMeta("markersBehindText", true)]);
    const en = log.delta(devB, 200, [setMeta("lang", "en-US")]);
    const s = reconstruct([en, es, base]);
    expect(s.meta.lang).toBe("en-US");
    expect(s.meta.markersBehindText).toBe(true);
  });

  it("does not let a snapshot without a clock beat an uncovered delta", () => {
    const log = new LogBuilder();
    const base = log.delta(devA, 0, [op.addPage(p1, "V")]);
    const es = log.delta(devA, 100, [setMeta("lang", "es-ES"), setMeta("markersBehindText", true)]);
    const snap = log.snapshot(devC, 500, [base]);
    expect(snapshotParts(snap).state.clocks?.lang).toBeUndefined();
    const merged = reconstruct([snap, es]);
    expect(merged.meta.lang).toBe("es-ES");
    expect(merged.meta.markersBehindText).toBe(true);
    const clear = log.delta(devA, 600, [setMeta("lang", null), setMeta("markersBehindText", false)]);
    const cleared = reconstruct([snap, es, clear]);
    expect(cleared.meta.lang).toBeUndefined();
    expect(cleared.meta.markersBehindText).toBeUndefined();
  });
});

describe("markers behind text", () => {
  function state(behind: boolean): NoteState {
    const log = new LogBuilder();
    const pen = stroke(), marker = stroke();
    marker.ink = { ...marker.ink, tool: "marker" };
    const ops: Op[] = [op.addPage(p1, "V"), op.addStroke(p1, pen), op.addStroke(p1, marker)];
    if (behind) ops.push(setMeta("markersBehindText", true));
    return reconstruct([log.delta(devA, 0, ops)]);
  }

  it("splits marker strokes out and draws them first", () => {
    const on = state(true), off = state(false);
    const page = on.pages[0], offPage = off.pages[0];
    if (!page || !offPage) throw new Error("no page");
    const prepared = new PreparedPage(page, on.meta);
    expect(prepared.strokeCommands(true).length).toBeGreaterThan(0);
    expect(prepared.strokeCommands(true).length + prepared.strokeCommands(false).length)
      .toBe(prepared.allStrokeCommands().length);
    expect(new PreparedPage(offPage, off.meta).strokeCommands(true)).toEqual([]);
    expect(prepared.underIndex()).toBe(0);
    // Without items the behind strokes simply come first in the SVG.
    const svg = pageSVG(page, on.meta);
    expect(svg.strokes).toEqual([...prepared.strokeCommands(true), ...prepared.strokeCommands(false)].map(elementSpec));
    expect(pageSVG(offPage, off.meta).strokes)
      .toEqual(new PreparedPage(offPage, off.meta).allStrokeCommands().map(elementSpec));
  });
});

describe("pdf page text", () => {
  it("reads only a well-formed value", () => {
    expect(pdfPageText({ kind: "pdfPage", pageText: { text: "Spectral", engine: "x" } })).toBe("Spectral");
    expect(pdfPageText({ kind: "pdfPage", pageText: "Spectral" })).toBe("");
    expect(pdfPageText({ kind: "pdfPage", pageText: { text: 3 } })).toBe("");
    expect(pdfPageText({ kind: "pdfPage" })).toBe("");
  });

  it("is searchable with the page's other text", () => {
    const log = new LogBuilder();
    const blob = { sha256: "a".repeat(64), size: 4, type: "application/pdf" };
    const item = {
      id: "6f1c2d4e-0000-4000-8000-000000000001", kind: "pdfPage", layer: 0, frame: [0, 0, 612, 792], z: "a0",
      blob, pageIndex: 0, pageSize: [612, 792], pageText: { text: "Eigenvalues", engine: "semperepdf-1" },
    };
    const ops: Op[] = [op.addPage(p1, "V"), decodeOp({ op: "addItem", page: p1, item }, "op", new Budget())];
    const s = reconstruct([log.delta(devA, 0, ops)]);
    const summary = summarize({ id: "n", state: s, failures: [], hasAttachments: true } as unknown as Parameters<typeof summarize>[0]);
    expect(summary.pageTexts).toEqual([{ number: 1, text: "Eigenvalues" }]);
  });
});
