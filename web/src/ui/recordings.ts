// A note's recordings (format.md §8.3): listed with their title, start and
// length; the audio is fetched only when Play is pressed, and a transcript
// only when it is opened. Both come from verified blobs (§8.1.4); a
// transcript that breaks §8.3.2 is reported like a blob that fails
// verification. Tapping a segment plays the recording from its start.

import type { JSONObject } from "../format/json.ts";
import { parseRFC3339 } from "../format/rfc3339.ts";
import { type Transcript, decodeTranscript, maxTranscriptBytes } from "../format/transcript.ts";
import { BlobError, type NoteBlobs, asBlobRef, essence, maxBlobSize } from "../vault/blobs.ts";
import { formatDate, h } from "./dom.ts";

/** `m:ss` or `h:mm:ss`. */
export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "";
  const t = Math.floor(seconds);
  const hh = Math.floor(t / 3600), mm = Math.floor((t % 3600) / 60), ss = t % 60;
  const two = (n: number) => String(n).padStart(2, "0");
  return hh > 0 ? `${hh}:${two(mm)}:${two(ss)}` : `${mm}:${two(ss)}`;
}

function problem(e: unknown): string {
  if (e instanceof BlobError && e.code === "missing") return "The audio file is missing from the vault.";
  return e instanceof Error ? e.message : String(e);
}

export class RecordingsPanel {
  readonly root: HTMLElement;
  private readonly urls: string[] = [];

  constructor(recordings: JSONObject[], private readonly blobs?: NoteBlobs) {
    this.root = h("details", { class: "recordings" },
      h("summary", { text: `${recordings.length} recording${recordings.length === 1 ? "" : "s"}` }),
      h("ul", {}, ...recordings.map((r) => this.row(r))));
    this.root.hidden = recordings.length === 0;
  }

  destroy(): void {
    for (const u of this.urls) URL.revokeObjectURL(u);
    this.urls.length = 0;
  }

  private row(rec: JSONObject): HTMLElement {
    const title = typeof rec.title === "string" && rec.title.trim() !== "" ? rec.title : "Recording";
    const started = typeof rec.started === "string" ? parseRFC3339(rec.started) : undefined;
    const duration = typeof rec.duration === "number" ? formatDuration(rec.duration) : "";
    const ref = asBlobRef(rec.blob);
    const transcriptRef = asBlobRef(rec.transcript);
    const status = h("p", { class: "rec-status", attrs: { role: "status" } });
    const player = h("div", { class: "rec-player" });
    const transcriptEl = h("div", { class: "transcript" });
    let loading: Promise<HTMLAudioElement | undefined> | undefined;

    const loadAudio = (): Promise<HTMLAudioElement | undefined> => {
      loading ??= (async () => {
        if (!ref || !this.blobs) {
          status.textContent = "The audio is not available.";
          return undefined;
        }
        if (!essence(ref.type).startsWith("audio/")) {
          status.textContent = `This recording's type (${ref.type}) cannot be played here.`;
          return undefined;
        }
        status.textContent = "Decrypting…";
        try {
          const blob = await this.blobs.get(ref, maxBlobSize);
          const url = URL.createObjectURL(new Blob([blob], { type: essence(ref.type) }));
          this.urls.push(url);
          const a = h("audio", { attrs: { controls: "", preload: "auto" } });
          a.addEventListener("error", () => {
            status.textContent = "This browser cannot play the recording's audio format.";
          });
          a.src = url;
          player.replaceChildren(a);
          status.textContent = "";
          return a;
        } catch (e) {
          status.textContent = problem(e);
          loading = undefined;
          return undefined;
        }
      })();
      return loading;
    };

    const play = h("button", {
      text: "Play", attrs: { type: "button" }, on: {
        click: () => {
          void loadAudio().then((a) => a?.play().catch(() => undefined));
        },
      },
    });
    player.append(play);

    const seek = (t: number) => {
      void loadAudio().then((a) => {
        if (!a) return;
        a.currentTime = t;
        void a.play().catch(() => undefined);
      });
    };

    let transcriptLoaded = false;
    const showTranscript = transcriptRef ? h("button", {
      text: "Transcript", attrs: { type: "button", "aria-expanded": "false" }, on: {
        click: () => {
          const open = transcriptEl.hidden || !transcriptLoaded;
          transcriptEl.hidden = !open;
          showTranscript?.setAttribute("aria-expanded", String(open));
          if (!open || transcriptLoaded || !this.blobs) return;
          transcriptLoaded = true;
          transcriptEl.replaceChildren(h("p", { class: "sub", text: "Decrypting…" }));
          void this.blobs.get(transcriptRef, maxTranscriptBytes).then(async (b) => {
            const t = decodeTranscript(new Uint8Array(await b.arrayBuffer()), String(rec.id));
            transcriptEl.replaceChildren(...transcriptView(t, seek));
          }).catch((e: unknown) => {
            transcriptEl.replaceChildren(h("p", { class: "error", text: `The transcript cannot be shown: ${problem(e)}` }));
          });
        },
      },
    }) : null;

    return h("li", { class: "recording" },
      h("div", { class: "rec-head" },
        h("span", { class: "title", text: title }),
        h("span", { class: "sub", text: [formatDate(started), duration].filter(Boolean).join(" · ") })),
      h("div", { class: "rec-actions" }, player, showTranscript),
      status, transcriptEl);
  }
}

/** Most segments listed at once; a longer transcript says how many are left out. */
const maxSegmentsShown = 5_000;

function transcriptView(t: Transcript, seek: (seconds: number) => void): HTMLElement[] {
  const shown = t.segments.slice(0, maxSegmentsShown);
  const list = h("ol", { class: "segments" }, ...shown.map((seg) => {
    const text = h("span", { class: "seg-text" });
    if (seg.words && seg.words.length > 0) {
      // Words the recogniser doubted (confidence under 0.5) are marked (§8.3.2).
      seg.words.forEach((w, i) => {
        if (i > 0) text.append(" ");
        text.append(w.c !== undefined && w.c < 0.5 ? h("span", { class: "doubtful", text: w.t, title: `confidence ${w.c}` }) : w.t);
      });
    } else {
      text.textContent = seg.text;
    }
    return h("li", {}, h("button", {
      class: "seg-time", text: formatDuration(seg.start), title: "Play from here", attrs: { type: "button" },
      on: { click: () => seek(seg.start) },
    }), text);
  }));
  const out = [h("p", { class: "sub", text: [t.language, t.engine].filter(Boolean).join(" · ") }), list];
  if (t.segments.length > shown.length) out.push(h("p", { class: "sub", text: `${t.segments.length - shown.length} more segments not shown.` }));
  return out;
}
