// Audio items (format.md §8.2.8): decoding, the immutable `recording`, the
// recording an item shows (through a restored copy's `parent`), the card's
// layout and label, and clipping the label to the card. The drawing itself
// is cross-checked with the Swift CLI (items-crosscheck).

import { describe, expect, it } from "vitest";
import { Budget, checkItemChange, decodeItem } from "../src/format/attachments.ts";
import { DecodeError, type JSONObject } from "../src/format/json.ts";
import type { Transcript } from "../src/format/transcript.ts";
import { audioCardCommands, audioCardLayout, audioLabel, clipLines, clock, recordingShownBy, transcriptExcerpt } from "../src/render/audio.ts";
import { layoutText } from "../src/render/text.ts";

const itemId = "6f1c2d4e-0000-4000-8000-000000000003";
const recId = "0d9e5c1a-0000-4000-8000-000000000001";

function decode(s: string): JSONObject {
  return decodeItem(JSON.parse(s), "$.ops[0].item", new Budget());
}

function transcript(texts: string[], language = "en-US"): Transcript {
  return { recording: recId, engine: "t", language, created: 0, segments: texts.map((text, i) => ({ start: i, end: i + 1, text })) };
}

describe("audio items (§8.2.8)", () => {
  it("decodes the format's example and rejects what Swift rejects", () => {
    const base = `{"id":"${itemId}","kind":"audio","frame":[72,144,300,96],"z":"a3"`;
    expect(decode(`${base},"recording":"${recId}"}`).recording).toBe(recId);
    for (const bad of [`${base}}`, `${base},"recording":"nope"}`, `${base},"recording":7}`]) {
      expect(() => decode(bad), bad).toThrow(DecodeError);
    }
    expect(() => checkItemChange("recording", recId, "$.ops[0].value")).toThrow(DecodeError);
  });

  it("finds the recording, or one restored from it", () => {
    const item = { kind: "audio", recording: recId };
    expect(recordingShownBy(item, [{ id: recId }])?.id).toBe(recId);
    expect(recordingShownBy(item, [{ id: "x", parent: recId }])?.id).toBe("x");
    expect(recordingShownBy(item, [{ id: "y" }])).toBeUndefined();
    expect(recordingShownBy({ kind: "text" }, [{ id: recId }])).toBeUndefined();
  });

  it("lays the card out like Swift's AudioCard", () => {
    const c = audioCardLayout({ x: 72, y: 144, w: 300, h: 96 });
    expect([c.padding, c.iconSize, c.iconCenter.x, c.iconCenter.y, c.labelBottom]).toEqual([8, 24, 92, 164, 232]);
    expect(c.labelFrame).toEqual({ x: 112, y: 152, w: 252, h: 80 });
    expect(audioCardLayout({ x: 0, y: 0, w: 10, h: 10 }).labelFrame).toBeUndefined();
    expect(audioCardCommands({ x: 0, y: 0, w: 300, h: 96 }, 0)).toHaveLength(6);
    expect(audioCardCommands({ x: 0, y: 0, w: 4, h: 4 }, 0)).toHaveLength(6);   // d = 0.8 m is always positive
  });

  it("builds the label: title, duration, transcript", () => {
    const text = (l: ReturnType<typeof audioLabel>) => l.runs.map((r) => r.t).join("");
    expect(text(audioLabel({ title: "Clase 1", duration: 75.4 }, transcript(["Hola\n a  todos.", "Bien."], "es-ES"))))
      .toBe("Clase 1 · 1:15\nHola a todos. Bien.");
    const l = audioLabel({ title: "  " }, transcript([], ""));
    expect(text(l)).toBe("Recording");
    expect(l.runs[0]?.style.bold).toBe(true);
    expect(text(audioLabel({ title: "a\nb", duration: 3725 }))).toBe("a b · 1:02:05");
    expect(clock(-1)).toBe("0:00");
    expect(Array.from(transcriptExcerpt(transcript(Array.from({ length: 1000 }, () => "word word"))) ?? "")).toHaveLength(2000);
  });

  it("clips the label at the card's bottom", () => {
    const content = audioLabel({ title: "T", duration: 1 }, transcript(["lorem ipsum ".repeat(100)]));
    const frame = { x: 0, y: 0, w: 150, h: 60 };
    const full = layoutText(content, frame);
    const cut = clipLines(full, 52);
    expect(cut.lines.length).toBeGreaterThan(1);
    expect(cut.lines.length).toBeLessThan(full.lines.length);
    for (const line of cut.lines) expect(line.baseline + 0.25 * line.size).toBeLessThanOrEqual(52 + 1e-6);
  });
});
