// Transcript search (docs/web-viewer.md "Search"): opt-in, like the CLI's
// `search --transcripts`, because it reads and decrypts every note and every
// transcript of the vault. Transcripts are read once per visit (the encrypted
// files come from the browser's cache when they are there) and kept in this
// tab's memory only; matches follow the CLI's rules (src/format/phrasesearch.ts).

import { type JSONObject } from "../format/json.ts";
import { trimTerm } from "../format/occurrences.ts";
import { type PhraseHit, type TranscriptRead, phraseQuery, transcriptHits } from "../format/phrasesearch.ts";
import { mapLimited } from "../vault/library.ts";
import { type BlobReader, readTranscripts } from "../vault/transcripts.ts";
import { type NoteState } from "../format/model.ts";
import { h } from "./dom.ts";

interface Indexed {
  title: string;
  notebook?: string;
  deleted: boolean;
  reads: TranscriptRead[];
}

/** Most transcript hits listed under one note in the list. */
export const maxHitsShown = 5;

export class TranscriptSearch {
  readonly element: HTMLElement;
  private readonly box: HTMLInputElement;
  private readonly status = h("span", { class: "hint", attrs: { role: "status" } });
  private readonly problems = h("ul", { class: "transcript-problems" });
  private readonly indexed = new Map<string, Indexed>();
  private readonly pending = new Set<string>();
  private failedNotes = 0;
  private running = false;
  private stopped = false;

  /**
   * `load` reads a note's state (undefined when it cannot be read), `blobs`
   * reads one of its blobs; `changed` runs when results may have changed.
   */
  constructor(private readonly load: (id: string) => Promise<NoteState | undefined>,
    private readonly blobs: (id: string) => BlobReader, private readonly changed: () => void) {
    this.box = h("input", { attrs: { type: "checkbox" } });
    this.box.addEventListener("change", () => this.changed());
    this.element = h("div", { class: "transcript-search" },
      h("label", { class: "check", title: "Reads and decrypts every recording's transcript in this tab (like sempere search --transcripts)" },
        this.box, " Also search recording transcripts"),
      this.status,
      h("details", { class: "warning", attrs: { hidden: "" } }, h("summary", {}), this.problems));
  }

  get enabled(): boolean {
    return this.box.checked;
  }

  /** Stops reading (the vault is being locked). */
  stop(): void {
    this.stopped = true;
  }

  /** Reads the transcripts of `ids` not read yet (call again as the list grows). */
  index(ids: string[]): void {
    if (!this.enabled || this.stopped) return;
    for (const id of ids) if (!this.indexed.has(id)) this.pending.add(id);
    if (!this.running && this.pending.size > 0) void this.run();
  }

  private async run(): Promise<void> {
    this.running = true;
    try {
      while (this.pending.size > 0 && !this.stopped) {
        const batch = [...this.pending];
        this.pending.clear();
        let done = 0;
        await mapLimited(batch, 4, async (id) => {
          if (this.stopped) return;
          let state: NoteState | undefined;
          try {
            state = await this.load(id);
          } catch {
            state = undefined;
          }
          if (!state) {
            this.failedNotes++;
            this.indexed.set(id, { title: "", deleted: false, reads: [] });
          } else {
            const reads = state.deleted ? [] : await readTranscripts(state, this.blobs(id));
            const entry: Indexed = { title: state.meta.title, deleted: state.deleted, reads };
            if (state.meta.notebook !== undefined) entry.notebook = state.meta.notebook;
            this.indexed.set(id, entry);
          }
          done++;
          this.status.textContent = ` Reading transcripts: ${done} of ${batch.length} notes…`;
          if (done % 8 === 0) this.changed();
        });
      }
    } finally {
      this.running = false;
    }
    if (this.stopped) return;
    this.report();
    this.changed();
  }

  private report(): void {
    let count = 0;
    const bad: { title: string; recording: JSONObject; error: string }[] = [];
    for (const n of this.indexed.values()) {
      for (const r of n.reads) {
        if (r.transcript) count++;
        else if (r.error !== undefined) bad.push({ title: n.title, recording: r.recording, error: r.error });
      }
    }
    this.status.textContent = ` ${count} transcript${count === 1 ? "" : "s"} searched`
      + (this.failedNotes ? ` · ${this.failedNotes} note${this.failedNotes === 1 ? "" : "s"} could not be read` : "");
    const details = this.problems.parentElement;
    if (!details) return;
    details.hidden = bad.length === 0;
    const summary = details.querySelector("summary");
    if (summary) summary.textContent = `${bad.length} transcript${bad.length === 1 ? "" : "s"} could not be read`;
    this.problems.replaceChildren(...bad.map((b) => h("li", {},
      `${b.title || "Untitled"}, ${typeof b.recording.title === "string" && b.recording.title ? b.recording.title : "recording"}: ${b.error}`)));
  }

  /** Transcript hits per note for `query` (CLI rules), each note's in time order; empty when off. */
  hits(query: string): Map<string, PhraseHit[]> {
    const out = new Map<string, PhraseHit[]>();
    const q = this.enabled ? phraseQuery(trimTerm(query)) : undefined;
    if (!q) return out;
    for (const [id, n] of this.indexed) {
      if (n.deleted) continue;
      const hits = n.reads.flatMap((r) => r.transcript ? transcriptHits(id, n.title, n.notebook, r.recording, r.transcript, q) : []);
      if (hits.length > 0) out.set(id, hits.sort((a, b) => (a.start ?? 0) - (b.start ?? 0)));
    }
    return out;
  }
}
