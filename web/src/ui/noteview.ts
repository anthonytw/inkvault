// The note view: pages stacked vertically (or one tall infinite page), drawn
// as SVG built from the same element specs `sempere export --format svg`
// writes, with pan and zoom (wheel, drag, pinch, keyboard). Pages are drawn
// lazily as they come near the viewport.

import { type NoteState, type Page, type Paper, paperKind, pointStride } from "../format/model.ts";
import { chunkHeight, defaultRenderOptions, pageSVG } from "../render/page.ts";
import { RenderLimits } from "../render/primitives.ts";
import { applyTransform, meanScale, transformOf } from "../render/stroke.ts";
import { h, s } from "./dom.ts";

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
  const e = Math.max(size.height, Math.ceil(low), chunkHeight(defaultRenderOptions, state.meta));
  return Number.isFinite(e) ? Math.min(e, RenderLimits.maxExtent) : size.height;
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

  constructor(private readonly state: NoteState) {
    this.content = h("div", { class: "pages" });
    this.viewport = h("div", { class: "viewport", attrs: { tabindex: "0", role: "region", "aria-label": "Note pages" } }, this.content);
    this.zoomLabel = h("span", { class: "zoom-label" });
    const button = (label: string, title: string, f: () => void) =>
      h("button", { text: label, title, attrs: { type: "button" }, on: { click: f } });
    const toolbar = h("div", { class: "zoom-bar" },
      button("−", "Zoom out (−)", () => this.zoomBy(1 / 1.25)), this.zoomLabel,
      button("+", "Zoom in (+)", () => this.zoomBy(1.25)),
      button("Fit", "Fit width (0)", () => this.fitWidth()), button("1:1", "Actual size (1)", () => this.setZoom(1)));
    this.root = h("div", { class: "note-canvas" }, toolbar, this.viewport);
    this.layout();
    this.bind();
    this.resize = new ResizeObserver(() => this.schedule());
    this.resize.observe(this.viewport);
    requestAnimationFrame(() => this.fitWidth());
  }

  destroy(): void {
    this.resize.disconnect();
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
      const slot = { page, index, top, left: (this.contentWidth - width) / 2, width, height, el, drawn: false };
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
      const p = pageSVG(slot.page, this.state.meta);
      const svg = s("svg", [["viewBox", `0 0 ${p.width} ${p.height}`], ["width", String(p.width)], ["height", String(p.height)]]);
      const paper = s("g"), ink = s("g");
      for (const e of p.paper) paper.append(s(e.tag, e.attrs));
      for (const e of p.strokes) ink.append(s(e.tag, e.attrs));
      svg.append(paper, ink);
      slot.el.style.height = `${p.height}px`;
      slot.el.replaceChildren(svg);
    } catch (e) {
      slot.el.replaceChildren(h("div", { class: "page-error", text: `Page ${slot.index + 1} cannot be drawn: ${e instanceof Error ? e.message : String(e)}` }));
    }
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
