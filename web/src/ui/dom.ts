// Tiny DOM builder. The viewer never parses markup (no innerHTML): every
// node is created with createElement / createElementNS and text is set as
// text, so note content can never become markup or script.

type Child = Node | string | null | undefined | false;

export interface Props {
  class?: string;
  text?: string;
  title?: string;
  attrs?: Record<string, string>;
  on?: Partial<{ [K in keyof HTMLElementEventMap]: (e: HTMLElementEventMap[K]) => void }>;
}

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Props = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (props.class) el.className = props.class;
  if (props.text !== undefined) el.textContent = props.text;
  if (props.title !== undefined) el.title = props.title;
  for (const [k, v] of Object.entries(props.attrs ?? {})) el.setAttribute(k, v);
  for (const [k, f] of Object.entries(props.on ?? {})) el.addEventListener(k, f as EventListener);
  for (const c of children) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}

export const svgNS = "http://www.w3.org/2000/svg";

/** Attributes the renderer emits; anything else is refused (defence in depth). */
const allowedSVGAttrs = new Set([
  "x", "y", "width", "height", "x1", "y1", "x2", "y2", "cx", "cy", "r", "points", "d", "fill", "fill-opacity",
  "stroke", "stroke-opacity", "stroke-width", "stroke-linecap", "stroke-linejoin", "viewBox",
]);
const allowedSVGTags = new Set(["svg", "g", "rect", "line", "circle", "polyline", "path"]);

export function s(tag: string, attrs: [string, string][] = []): SVGElement {
  if (!allowedSVGTags.has(tag)) throw new Error(`unexpected SVG element ${tag}`);
  const el = document.createElementNS(svgNS, tag);
  for (const [k, v] of attrs) {
    if (!allowedSVGAttrs.has(k)) throw new Error(`unexpected SVG attribute ${k}`);
    el.setAttribute(k, v);
  }
  return el;
}

export function clear(el: Element): void {
  el.replaceChildren();
}

export function formatDate(ms: number | undefined): string {
  if (ms === undefined) return "";
  return new Date(ms).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}
