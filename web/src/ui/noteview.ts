// The note view: pages stacked vertically (or one tall infinite page), drawn
// as SVG built from the same element specs `sempere export --format svg`
// writes, with pan and zoom (wheel, drag, pinch, keyboard). Pages are drawn
// lazily as they come near the viewport.

import { type NoteState, type Page, type Paper, paperKind, pointStride } from "../format/model.ts";
import { imageInfo, imageLimits, stripMetadata } from "../render/images.ts";
import {
  type PreparedItem, after, imageTransform, maxItemsPerPage, pdfCrop, placement, prepareItem, translate,
} from "../render/items.ts";
import { type ItemDraw, placeholderNodes, rasterNode, resolveItems, textNode } from "../render/itemsvg.ts";
import { PreparedPage, chunkHeight, defaultRenderOptions, elementSpec } from "../render/page.ts";
import { RenderLimits } from "../render/primitives.ts";
import { applyTransform, meanScale, transformOf } from "../render/stroke.ts";
import { type Measure, fontStacks } from "../render/text.ts";
import { BlobError, type NoteBlobs } from "../vault/blobs.ts";
import { h, s, svgTree } from "./dom.ts";
import { NotePDFs, maxPDFBytes } from "./pdf.ts";

const gap = 24;
const minZoom = 0.05, maxZoom = 12;

/** A page's drawn height without outlining it (PreparedPage's extent rule). */
export function pageExtent(page: Page, state: NoteState): number {
  const size = state.meta.pageSize;
  if (!size.infinite) return size.height;
  let low = 0;
  for (const st of page.strokes) {
    const n = st.points.length / pointStride;
    const xf = transformOf(st);
    let radius = Math.abs(st.ink.width), hi = -Infinity;
    for (let i = 0; i < n; i++) {
      const b = i * pointStride;
      const q = applyTransform(xf, st.points[b] ?? 0, st.points[b + 1] ?? 0);
      hi = Math.max(hi, q.y);
      radius = Math.max(radius, Math.abs(st.points[b + 3] ?? 0), Math.abs(st.points[b + 4] ?? 0));
    }
    if (n > 0) low = Math.max(low, hi + Math.min(radius * meanScale(xf), RenderLimits.maxNibWidth) / 2 + 1);
  }
  for (const item of page.items.slice(0, maxItemsPerPage)) {
    const p = prepareItem(item);
    if (typeof p !== "string") low = Math.max(low, p.maxY);
  }
  const e = Math.max(size.height, Math.ceil(low), chunkHeight(defaultRenderOptions, state.meta));
  return Number.isFinite(e) ? Math.min(e, RenderLimits.maxExtent) : size.height;
}

let measureContext: CanvasRenderingContext2D | null | undefined;

/** Text widths from the browser's fonts, for text boxes without usable stored breaks (§8.5.3). */
const canvasMeasure: Measure = (text, style, font) => {
  measureContext ??= document.createElement("canvas").getContext("2d");
  if (!measureContext) return text.length * style.size * 0.5;
  measureContext.font = `${style.italic ? "italic " : ""}${style.bold ? "bold " : ""}${style.size}px ${fontStacks[font]}`;
  return measureContext.measureText(text).width;
};

/** An image or PDF page waiting to be fetched until it comes on screen. */
interface PendingItem {
  draw: Extract<ItemDraw, { kind: "image" | "pdf" }>;
  g: SVGElement;
  minX: number;
  maxX: number;
  state: "idle" | "loading" | "done";
  /** PDF pages: pixels per point of the current rendering. */
  scale?: number;
  url?: string;
}

/** An item drawn as a placeholder, and why (format.md §8.5.2). */
export interface ItemProblem {
  page: number;
  item: string;
  kind: string;
  reason: string;
}

let viewCount = 0;

function why(e: unknown): string {
  if (e instanceof BlobError) return e.code === "missing" ? "attachment file is missing" : `attachment unreadable: ${e.message}`;
  return e instanceof Error ? e.message : String(e);
}

interface Slot {
  page: Page;
  index: number;
  top: number;
  left: number;
  width: number;
  height: number;
  el: HTMLElement;
  drawn: boolean;
  pending: PendingItem[];
}

export class NoteView {
  readonly root: HTMLElement;
  private readonly viewport: HTMLElement;
  private readonly content: HTMLElement;
  private readonly zoomLabel: HTMLElement;
  private slots: Slot[] = [];
  private x = 0;
  private y = 0;
  private z = 1;
  private contentWidth = 1;
  private contentHeight = 1;
  private pending = false;
  private readonly pointers = new Map<number, { x: number; y: number }>();
  private pinch?: { dist: number; z: number; cx: number; cy: number };
  private readonly resize: ResizeObserver;
  private readonly uid = `n${++viewCount}`;
  private readonly pdfs = new NotePDFs();
  private readonly urls = new Set<string>();
  private readonly problems = new Map<string, ItemProblem>();
  /** The list of placeholders and why; the caller puts it with the note's other warnings. */
  readonly problemsEl = h("details", { class: "warning item-problems" });
  private destroyed = false;
  private rerender?: ReturnType<typeof setTimeout>;

  /** `blobs` reads the note's attachments; without it every image and PDF page is a placeholder. */
  constructor(private readonly state: NoteState, private readonly blobs?: NoteBlobs) {
    this.content = h("div", { class: "pages" });
    this.viewport = h("div", { class: "viewport", attrs: { tabindex: "0", role: "region", "aria-label": "Note pages" } }, this.content);
    this.zoomLabel = h("span", { class: "zoom-label" });
    const button = (label: string, title: string, f: () => void) =>
      h("button", { text: label, title, attrs: { type: "button" }, on: { click: f } });
    const toolbar = h("div", { class: "zoom-bar" },
      button("−", "Zoom out (−)", () => this.zoomBy(1 / 1.25)), this.zoomLabel,
      button("+", "Zoom in (+)", () => this.zoomBy(1.25)),
      button("Fit", "Fit width (0)", () => this.fitWidth()), button("1:1", "Actual size (1)", () => this.setZoom(1)));
    this.problemsEl.hidden = true;
    this.root = h("div", { class: "note-canvas" }, toolbar, this.viewport);
    this.layout();
    this.bind();
    this.resize = new ResizeObserver(() => this.schedule());
    this.resize.observe(this.viewport);
    requestAnimationFrame(() => this.fitWidth());
  }

  destroy(): void {
    this.destroyed = true;
    this.resize.disconnect();
    clearTimeout(this.rerender);
    this.pdfs.destroy();
    for (const u of this.urls) URL.revokeObjectURL(u);
    this.urls.clear();
  }

  /** Items drawn as placeholders so far (only items that came on screen are tried). */
  itemProblems(): ItemProblem[] {
    return [...this.problems.values()];
  }

  /** Records an item that is a placeholder or not drawn, and why (`it` undefined: a page-level note). */
  private report(slot: Slot, it: PreparedItem | undefined, reason: string): void {
    const id = it ? String(it.item.id) : `-${this.problems.size}`;
    this.problems.set(`${slot.index}/${id}`, { page: slot.index + 1, item: it ? id : "", kind: it?.kind ?? "", reason });
    const list = [...this.problems.values()];
    this.problemsEl.hidden = false;
    this.problemsEl.replaceChildren(
      h("summary", { text: `${list.length} attachment${list.length === 1 ? "" : "s"} cannot be shown (crossed boxes on the page)` }),
      h("ul", {}, ...list.map((p) => h("li", { text: `Page ${p.page}: ${p.item ? `${p.kind} ${p.item.slice(0, 8)}: ` : ""}${p.reason}` }))));
  }

  private layout(): void {
    const pages = this.state.pages;
    this.contentWidth = Math.max(1, ...pages.map(() => this.state.meta.pageSize.width));
    let top = 0;
    this.slots = pages.map((page, index) => {
      const width = this.state.meta.pageSize.width;
      let height: number;
      try {
        height = pageExtent(page, this.state);
      } catch {
        height = 200;
      }
      if (!(height > 0)) height = 200;
      const el = h("div", { class: "page", attrs: { "aria-label": `Page ${index + 1}` } },
        h("div", { class: "page-placeholder", text: `Page ${index + 1}` }));
      el.style.width = `${width}px`;
      el.style.height = `${height}px`;
      el.style.left = `${(this.contentWidth - width) / 2}px`;
      el.style.top = `${top}px`;
      const slot: Slot = { page, index, top, left: (this.contentWidth - width) / 2, width, height, el, drawn: false, pending: [] };
      top += height + gap;
      this.content.append(el);
      return slot;
    });
    this.contentHeight = Math.max(top - gap, 1);
    this.content.style.width = `${this.contentWidth}px`;
    this.content.style.height = `${this.contentHeight}px`;
  }

  private draw(slot: Slot): void {
    slot.drawn = true;
    try {
      const prepared = new PreparedPage(slot.page, this.state.meta);
      const width = this.state.meta.pageSize.width, height = prepared.extent;
      const svg = s("svg", [["viewBox", `0 0 ${width} ${height}`], ["width", String(width)], ["height", String(height)]]);
      const paper = s("g"), items = s("g"), ink = s("g");
      for (const c of prepared.fullPagePaper()) {
        const e = elementSpec(c);
        paper.append(s(e.tag, e.attrs));
      }
      for (const w of prepared.warnings) this.report(slot, undefined, w);
      for (const r of resolveItems(prepared, canvasMeasure)) {
        if (r.fill) items.append(s(r.fill.tag, r.fill.attrs));
        const d = r.draw;
        switch (d.kind) {
          case "placeholder":
            for (const n of placeholderNodes(d.it)) items.append(svgTree(n));
            this.report(slot, d.it, d.reason);
            break;
          case "text":
            items.append(svgTree(textNode(d.it, d.content, d.layout)));
            break;
          default: {
            const g = s("g");
            items.append(g);
            const xs = d.it.corners.map((p) => p.x);
            slot.pending.push({ draw: d, g, minX: Math.min(...xs), maxX: Math.max(...xs), state: "idle" });
          }
        }
      }
      for (const c of prepared.allStrokeCommands()) {
        const e = elementSpec(c);
        ink.append(s(e.tag, e.attrs));
      }
      svg.append(paper, items, ink);
      slot.el.style.height = `${height}px`;
      slot.el.replaceChildren(svg);
    } catch (e) {
      slot.el.replaceChildren(h("div", { class: "page-error", text: `Page ${slot.index + 1} cannot be drawn: ${e instanceof Error ? e.message : String(e)}` }));
    }
  }

  /** Pixels per point a PDF crop needs at the current zoom (at least 2, at most 8). */
  private pdfScale(p: PendingItem): number {
    const d = p.draw as Extract<ItemDraw, { kind: "pdf" }>;
    const crop = pdfCrop(d.it, d.pageSize.w, d.pageSize.h);
    const perPoint = Math.max(d.it.frame.w / crop.w, d.it.frame.h / crop.h);
    return Math.min(Math.max(perPoint * this.z * (globalThis.devicePixelRatio || 1), 2), 8);
  }

  /** Fetches and draws the images and PDF pages that are on screen (or nearly). */
  private loadVisible(top: number, bottom: number, left: number, right: number): void {
    let wantsSharper = false;
    for (const slot of this.slots) {
      if (!slot.drawn || slot.top > bottom || slot.top + slot.height < top) continue;
      for (const p of slot.pending) {
        const it = p.draw.it;
        if (slot.top + it.maxY < top || slot.top + it.minY > bottom || slot.left + p.maxX < left || slot.left + p.minX > right) continue;
        if (p.state === "idle") void this.load(slot, p);
        else if (p.state === "done" && p.draw.kind === "pdf" && p.scale !== undefined && this.pdfScale(p) > p.scale * 1.5) wantsSharper = true;
      }
    }
    if (wantsSharper) {
      clearTimeout(this.rerender);
      this.rerender = setTimeout(() => this.sharpen(top, bottom), 400);
    }
  }

  private sharpen(top: number, bottom: number): void {
    for (const slot of this.slots) {
      for (const p of slot.pending) {
        const it = p.draw.it;
        if (p.state !== "done" || p.draw.kind !== "pdf" || p.scale === undefined) continue;
        if (slot.top + it.maxY < top || slot.top + it.minY > bottom) continue;
        if (this.pdfScale(p) > p.scale * 1.5) void this.load(slot, p);
      }
    }
  }

  private async load(slot: Slot, p: PendingItem): Promise<void> {
    p.state = "loading";
    const d = p.draw;
    const clipId = `${this.uid}-p${slot.index}-i${slot.pending.indexOf(p)}`;
    try {
      if (!this.blobs) throw new Error("attachments are not available");
      let url: string, width: number, height: number, transform;
      if (d.kind === "image") {
        const bytes = new Uint8Array(await (await this.blobs.get(d.ref, imageLimits.maxBlobBytes)).arrayBuffer());
        const info = imageInfo(bytes);
        const m = imageTransform(d.it, info.width, info.height);
        if (typeof m === "string") throw new Error(m);
        url = this.url(new Blob([stripMetadata(bytes) as Uint8Array<ArrayBuffer>], { type: info.type }));
        const img = new Image();
        img.src = url;
        try {
          await img.decode();
        } catch {
          throw new Error("the image cannot be decoded");
        }
        if (img.naturalWidth !== info.width || img.naturalHeight !== info.height) throw new Error("the image does not decode to its stated size");
        ({ width, height } = info);
        transform = m;
      } else {
        const blobs = this.blobs;
        const doc = await this.pdfs.document(d.ref.sha256, async () => new Uint8Array(await (await blobs.get(d.ref, maxPDFBytes)).arrayBuffer()));
        const page = await this.pdfs.page(doc, d.pageIndex);
        const eff = NotePDFs.effectiveSize(page);
        const crop = pdfCrop(d.it, eff.w, eff.h);
        const scale = this.pdfScale(p);
        const canvas = await this.pdfs.render(page, crop, scale);
        const png = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
        if (!png) throw new Error("the PDF page cannot be drawn");
        url = this.url(png);
        width = crop.w;
        height = crop.h;
        transform = after(placement(crop, d.it.frame, d.it.rotation), translate(crop.x, crop.y));
        p.scale = scale;
      }
      if (this.destroyed) {
        URL.revokeObjectURL(url);
        return;
      }
      if (p.url) URL.revokeObjectURL(p.url);
      this.urls.delete(p.url ?? "");
      p.url = url;
      p.g.replaceChildren(svgTree(rasterNode(d.it, url, width, height, transform, clipId)));
      p.state = "done";
    } catch (e) {
      if (this.destroyed) return;
      p.state = "done";
      // A sharper rendering that failed keeps the one already shown, and is not tried again.
      if (p.url) {
        p.scale = Infinity;
        return;
      }
      p.scale = undefined;
      p.g.replaceChildren(...placeholderNodes(d.it).map(svgTree));
      this.report(slot, d.it, why(e));
    }
  }

  private url(b: Blob): string {
    const u = URL.createObjectURL(b);
    this.urls.add(u);
    return u;
  }

  private schedule(): void {
    if (this.pending) return;
    this.pending = true;
    requestAnimationFrame(() => {
      this.pending = false;
      this.apply();
    });
  }

  private apply(): void {
    this.content.style.transform = `translate(${this.x}px, ${this.y}px) scale(${this.z})`;
    this.zoomLabel.textContent = `${Math.round(this.z * 100)}%`;
    const vh = this.viewport.clientHeight;
    const top = (-this.y - vh) / this.z, bottom = (-this.y + 2 * vh) / this.z;
    for (const slot of this.slots) {
      if (!slot.drawn && slot.top + slot.height >= top && slot.top <= bottom) this.draw(slot);
    }
    // Attachments load only when on screen (half a screen ahead).
    const vw = this.viewport.clientWidth;
    this.loadVisible((-this.y - vh / 2) / this.z, (-this.y + 1.5 * vh) / this.z, (-this.x - vw / 2) / this.z, (-this.x + 1.5 * vw) / this.z);
  }

  private clampPan(): void {
    const vw = this.viewport.clientWidth, vh = this.viewport.clientHeight;
    const w = this.contentWidth * this.z, ht = this.contentHeight * this.z;
    const margin = 40;
    this.x = w + 2 * margin <= vw ? (vw - w) / 2 : Math.min(margin, Math.max(vw - w - margin, this.x));
    this.y = Math.min(margin, Math.max(Math.min(vh - ht - margin, margin), this.y));
  }

  private setZoom(z: number, cx = this.viewport.clientWidth / 2, cy = this.viewport.clientHeight / 2): void {
    const nz = Math.min(Math.max(z, minZoom), maxZoom);
    this.x = cx - ((cx - this.x) * nz) / this.z;
    this.y = cy - ((cy - this.y) * nz) / this.z;
    this.z = nz;
    this.clampPan();
    this.schedule();
  }

  private zoomBy(f: number, cx?: number, cy?: number): void {
    this.setZoom(this.z * f, cx, cy);
  }

  fitWidth(): void {
    const vw = this.viewport.clientWidth || 800;
    this.z = Math.min(Math.max((vw - 32) / this.contentWidth, minZoom), 4);
    this.x = (vw - this.contentWidth * this.z) / 2;
    this.y = 16;
    this.clampPan();
    this.schedule();
  }

  private panBy(dx: number, dy: number): void {
    this.x += dx;
    this.y += dy;
    this.clampPan();
    this.schedule();
  }

  private local(e: { clientX: number; clientY: number }): { x: number; y: number } {
    const r = this.viewport.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  private bind(): void {
    const v = this.viewport;
    v.addEventListener("wheel", (e) => {
      e.preventDefault();
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? v.clientHeight : 1;
      if (e.ctrlKey || e.metaKey) {
        const p = this.local(e);
        this.zoomBy(Math.exp(-e.deltaY * unit * 0.01), p.x, p.y);
      } else {
        this.panBy(-e.deltaX * unit, -e.deltaY * unit);
      }
    }, { passive: false });
    v.addEventListener("pointerdown", (e) => {
      v.setPointerCapture(e.pointerId);
      this.pointers.set(e.pointerId, this.local(e));
      if (this.pointers.size === 2) {
        const [a, b] = [...this.pointers.values()] as [{ x: number; y: number }, { x: number; y: number }];
        this.pinch = { dist: Math.hypot(a.x - b.x, a.y - b.y), z: this.z, cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2 };
      }
    });
    v.addEventListener("pointermove", (e) => {
      const prev = this.pointers.get(e.pointerId);
      if (!prev) return;
      const p = this.local(e);
      this.pointers.set(e.pointerId, p);
      if (this.pointers.size === 1) {
        this.panBy(p.x - prev.x, p.y - prev.y);
      } else if (this.pointers.size === 2 && this.pinch) {
        const [a, b] = [...this.pointers.values()] as [{ x: number; y: number }, { x: number; y: number }];
        const cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
        this.panBy(cx - this.pinch.cx, cy - this.pinch.cy);
        this.pinch.cx = cx;
        this.pinch.cy = cy;
        const dist = Math.hypot(a.x - b.x, a.y - b.y);
        if (this.pinch.dist > 0) this.setZoom((this.pinch.z * dist) / this.pinch.dist, cx, cy);
      }
    });
    const up = (e: PointerEvent) => {
      this.pointers.delete(e.pointerId);
      if (this.pointers.size < 2) this.pinch = undefined;
    };
    v.addEventListener("pointerup", up);
    v.addEventListener("pointercancel", up);
    v.addEventListener("keydown", (e) => {
      const step = 60;
      const keys: Record<string, () => void> = {
        "+": () => this.zoomBy(1.25), "=": () => this.zoomBy(1.25), "-": () => this.zoomBy(1 / 1.25),
        "0": () => this.fitWidth(), "1": () => this.setZoom(1),
        ArrowUp: () => this.panBy(0, step), ArrowDown: () => this.panBy(0, -step),
        ArrowLeft: () => this.panBy(step, 0), ArrowRight: () => this.panBy(-step, 0),
        PageUp: () => this.panBy(0, v.clientHeight * 0.9), PageDown: () => this.panBy(0, -v.clientHeight * 0.9),
        " ": () => this.panBy(0, -v.clientHeight * 0.9),
        Home: () => { this.y = 16; this.clampPan(); this.schedule(); },
        End: () => { this.y = -Infinity; this.clampPan(); this.schedule(); },
      };
      const f = keys[e.key];
      if (f && !e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        f();
      }
    });
  }

  /** Scrolls so page `number` (1-based) is at the top. */
  showPage(number: number): void {
    const slot = this.slots[number - 1];
    if (!slot) return;
    this.y = 16 - slot.top * this.z;
    this.clampPan();
    this.schedule();
  }
}

/** True when some page uses a paper kind this viewer does not know (drawn blank, §5.4.2). */
export function hasUnknownPaper(state: NoteState): boolean {
  const known = (p: Paper) => paperKind(p) === p.kindName;
  return !known(state.meta.paper) || state.pages.some((p) => p.paper !== undefined && !known(p.paper));
}
