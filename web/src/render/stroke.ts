// Stroke geometry: uniform cubic B-spline evaluation as PencilKit's
// `PKStrokePath`, adaptive sampling, and variable-width outlines. A port of
// Sources/SempereRender/Geometry.swift and StrokeOutline.swift; the output must
// match `sempere export --format svg` exactly (test/golden).

import { type InkTool, type Stroke, pointStride } from "../format/model.ts";
import {
  type DrawCommand, type Point, RenderLimits, type Subpath, clamp01, distance, paint, signedArea,
} from "./primitives.ts";

export interface Sample {
  x: number;
  y: number;
  w: number;
  h: number;
  o: number;
  f: number;
}

const X = 0, Y = 1, W = 3, H = 4, O = 5, F = 6;

function at(p: Float64Array, i: number, field: number): number {
  return p[i * pointStride + field] ?? 0;
}

function segment(n: number, t: number): [number, number] {
  const c = Math.min(Math.max(Number.isNaN(t) ? 0 : t, 0), n - 1);
  const i = Math.min(Math.floor(c), n - 2);
  return [i, c - i];
}

function control(p: Float64Array, n: number, j: number): [number, number] {
  if (j < 0) return [2 * at(p, 0, X) - at(p, 1, X), 2 * at(p, 0, Y) - at(p, 1, Y)];
  if (j >= n) return [2 * at(p, n - 1, X) - at(p, n - 2, X), 2 * at(p, n - 1, Y) - at(p, n - 2, Y)];
  return [at(p, j, X), at(p, j, Y)];
}

/** Location at parameter `t`, untransformed. */
export function location(p: Float64Array, t: number): Point {
  const n = p.length / pointStride;
  if (n === 0) return { x: 0, y: 0 };
  if (n === 1) return { x: at(p, 0, X), y: at(p, 0, Y) };
  const [i, u] = segment(n, t);
  const c0 = control(p, n, i - 1), c1 = control(p, n, i), c2 = control(p, n, i + 1), c3 = control(p, n, i + 2);
  const u2 = u * u, u3 = u2 * u;
  const b0 = (1 - u) * (1 - u) * (1 - u) / 6;
  const b1 = (3 * u3 - 6 * u2 + 4) / 6;
  const b2 = (-3 * u3 + 3 * u2 + 3 * u + 1) / 6;
  const b3 = u3 / 6;
  return {
    x: b0 * c0[0] + b1 * c1[0] + b2 * c2[0] + b3 * c3[0],
    y: b0 * c0[1] + b1 * c1[1] + b2 * c2[1] + b3 * c3[1],
  };
}

/** Full sample at `t`: location on the B-spline, other attributes linear. */
export function sampleAt(p: Float64Array, t: number): Sample {
  const n = p.length / pointStride;
  if (n === 0) return { x: 0, y: 0, w: 0, h: 0, o: 0, f: 0 };
  const loc = location(p, t);
  if (n === 1) return { x: loc.x, y: loc.y, w: at(p, 0, W), h: at(p, 0, H), o: at(p, 0, O), f: at(p, 0, F) };
  const [i, u] = segment(n, t);
  const lerp = (field: number) => {
    const a = at(p, i, field), b = at(p, i + 1, field);
    return a + (b - a) * u;
  };
  return { x: loc.x, y: loc.y, w: lerp(W), h: lerp(H), o: lerp(O), f: lerp(F) };
}

type Transform = [number, number, number, number, number, number];

export function transformOf(s: Stroke): Transform {
  const t = s.transform;
  return t ? [t[0] ?? 1, t[1] ?? 0, t[2] ?? 0, t[3] ?? 1, t[4] ?? 0, t[5] ?? 0] : [1, 0, 0, 1, 0, 0];
}

export function applyTransform(t: Transform, x: number, y: number): Point {
  return { x: t[0] * x + t[2] * y + t[4], y: t[1] * x + t[3] * y + t[5] };
}

/** Uniform scale for widths: `sqrt(|det|)`; non-finite collapses to 0. */
export function meanScale(t: Transform): number {
  const det = Math.abs(t[0] * t[3] - t[1] * t[2]);
  return Number.isFinite(det) ? Math.sqrt(det) : 0;
}

function pt(s: Sample): Point {
  return { x: s.x, y: s.y };
}

/**
 * Adaptive samples of a stroke's curve with its transform applied: at least
 * two for any non-empty stroke, none for an empty one.
 */
export function samples(stroke: Stroke, tolerance = 0.05, maxSpacing = 1.0, offsetY = 0): Sample[] {
  const pts = stroke.points;
  const count = pts.length / pointStride;
  if (count === 0) return [];
  const xf = transformOf(stroke);
  const scale = meanScale(xf);
  const tol = Number.isFinite(tolerance) ? Math.max(tolerance, 1e-4) : 0.05;
  const cap = Number.isFinite(maxSpacing) ? Math.max(maxSpacing, 0.01) : 1.0;

  const evaluate = (t: number): Sample => {
    const s = sampleAt(pts, t);
    const p = applyTransform(xf, s.x, s.y);
    return { x: p.x, y: p.y + offsetY, w: s.w * scale, h: s.h * scale, o: s.o, f: s.f };
  };

  const segments = count - 1;
  const budget = RenderLimits.samplesPerPoint * count + RenderLimits.baseSamples;
  let maxDepth = 12;
  while (maxDepth > 1 && segments > Math.floor(budget / 2 ** maxDepth)) maxDepth -= 1;

  const out: Sample[] = [evaluate(0)];
  if (count > 1) {
    const subdivide = (t0: number, s0: Sample, t1: number, s1: Sample, depth: number): void => {
      const tm = (t0 + t1) / 2;
      const sm = evaluate(tm);
      const chord = distance(pt(s0), pt(s1));
      const mid = { x: (s0.x + s1.x) / 2, y: (s0.y + s1.y) / 2 };
      const flat = distance(pt(sm), mid) <= tol;
      const limit = flat ? cap * 4 : cap;
      if (depth < maxDepth && (depth === 0 || !flat || chord > limit)) {
        subdivide(t0, s0, tm, sm, depth + 1);
        subdivide(tm, sm, t1, s1, depth + 1);
      } else {
        out.push(s1);
      }
    };
    for (let i = 0; i < count - 1; i++) {
      subdivide(i, out[out.length - 1] as Sample, i + 1, evaluate(i + 1), 0);
    }
  }

  // Drop coincident neighbours (repeated control points).
  const dedup: Sample[] = [];
  for (const s of out) {
    const last = dedup[dedup.length - 1];
    if (last && distance(pt(last), pt(s)) < 1e-9) continue;
    dedup.push(s);
  }
  if (dedup.length < 2) {
    const only = dedup[0] ?? out[0];
    return only ? [only, only] : [];
  }
  return dedup;
}

/** Opacity multiplier per tool, on top of colour alpha and sample opacity. */
export function toolOpacity(tool: InkTool): number {
  switch (tool) {
    case "pen": case "fountainPen": case "monoline": return 1;
    case "marker": return 0.5;
    case "pencil": return 0.8;
    case "crayon": return 0.85;
    case "watercolor": return 0.5;
  }
}

export function opacityFactor(stroke: Stroke, s: Sample[]): number {
  const meanO = s.length === 0 ? 1 : s.reduce((n, x) => n + x.o, 0) / s.length;
  return clamp01(meanO) * toolOpacity(stroke.ink.tool);
}

/** Unit-circle vertices (32 segments) written out, as in Swift, so no libm call sits in the output path. */
const unitCircle: [number, number][] = [
  [1.0, 0.0], [0.9807852804032304, 0.1950903220161282], [0.9238795325112867, 0.3826834323650898],
  [0.8314696123025452, 0.5555702330196022], [0.7071067811865476, 0.7071067811865475],
  [0.5555702330196023, 0.8314696123025452], [0.3826834323650898, 0.9238795325112867],
  [0.1950903220161283, 0.9807852804032304], [1e-16, 1.0], [-0.1950903220161282, 0.9807852804032304],
  [-0.3826834323650897, 0.9238795325112867], [-0.555570233019602, 0.8314696123025453],
  [-0.7071067811865475, 0.7071067811865476], [-0.8314696123025453, 0.5555702330196022],
  [-0.9238795325112867, 0.3826834323650899], [-0.9807852804032304, 0.1950903220161286], [-1.0, 1e-16],
  [-0.9807852804032304, -0.1950903220161284], [-0.9238795325112868, -0.3826834323650897],
  [-0.8314696123025455, -0.555570233019602], [-0.7071067811865477, -0.7071067811865475],
  [-0.5555702330196022, -0.8314696123025452], [-0.3826834323650903, -0.9238795325112865],
  [-0.1950903220161287, -0.9807852804032303], [-2e-16, -1.0], [0.1950903220161283, -0.9807852804032304],
  [0.38268343236509, -0.9238795325112866], [0.5555702330196018, -0.8314696123025455],
  [0.7071067811865474, -0.7071067811865477], [0.8314696123025452, -0.5555702330196022],
  [0.9238795325112865, -0.3826834323650904], [0.9807852804032303, -0.1950903220161287],
];

export function circle(c: Point, r: number): Subpath {
  return { points: unitCircle.map(([x, y]) => ({ x: c.x + r * x, y: c.y + r * y })), closed: true };
}

function oriented(s: Subpath): Subpath {
  return signedArea(s) < 0 ? { points: [...s.points].reverse(), closed: true } : s;
}

function isDot(s: Sample[]): boolean {
  const first = s[0];
  return first !== undefined && s.every((x) => distance(pt(x), pt(first)) < 1e-9);
}

/** Variable-width ribbon: one quad per segment plus round caps and joins, for a non-zero fill. */
export function ribbon(s: Sample[], fallbackWidth: number): Subpath[] {
  if (s.length === 0) return [];
  const radius = (x: Sample) => Math.min(Math.max(x.w > 0 ? x.w : fallbackWidth, 0.05), RenderLimits.maxNibWidth) / 2;
  if (isDot(s)) {
    return [circle(pt(s[0] as Sample), s.map(radius).reduce((m, r) => Math.max(m, r), -Infinity))];
  }
  const polys: Subpath[] = [];
  const n = s.length;
  for (let i = 0; i < n - 1; i++) {
    const sa = s[i] as Sample, sb = s[i + 1] as Sample;
    const a = pt(sa), b = pt(sb);
    const len = distance(a, b);
    if (len <= 1e-9) continue;
    const nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len;
    const ra = radius(sa), rb = radius(sb);
    polys.push(oriented({
      points: [{ x: a.x + nx * ra, y: a.y + ny * ra }, { x: b.x + nx * rb, y: b.y + ny * rb },
        { x: b.x - nx * rb, y: b.y - ny * rb }, { x: a.x - nx * ra, y: a.y - ny * ra }],
      closed: true,
    }));
  }
  polys.push(circle(pt(s[0] as Sample), radius(s[0] as Sample)));
  polys.push(circle(pt(s[n - 1] as Sample), radius(s[n - 1] as Sample)));
  for (let i = 1; i < n - 1; i++) {
    const p = pt(s[i - 1] as Sample), q = pt(s[i] as Sample), r = pt(s[i + 1] as Sample);
    const l1 = distance(p, q), l2 = distance(q, r);
    if (l1 <= 1e-9 || l2 <= 1e-9) continue;
    const cos = ((q.x - p.x) * (r.x - q.x) + (q.y - p.y) * (r.y - q.y)) / (l1 * l2);
    if (cos < 0.97) polys.push(circle(q, radius(s[i] as Sample)));
  }
  return polys;
}

/** Draw commands for one stroke (empty for a stroke with no points). */
export function strokeCommands(stroke: Stroke, tolerance = 0.05, offsetY = 0): DrawCommand[] {
  const s = samples(stroke, tolerance, 1.0, offsetY);
  if (s.length === 0) return [];
  const scale = meanScale(transformOf(stroke));
  const fill = paint(stroke.ink.color, opacityFactor(stroke, s));
  if (stroke.ink.tool === "monoline") {
    const width = Math.min(Math.max(stroke.ink.width * scale, 0.05), RenderLimits.maxNibWidth);
    if (isDot(s)) {
      return [{ primitive: { kind: "path", subpaths: [circle(pt(s[0] as Sample), width / 2)] }, fill, lineWidth: 1 }];
    }
    return [{ primitive: { kind: "path", subpaths: [{ points: s.map(pt), closed: false }] }, stroke: fill, lineWidth: width }];
  }
  const polys = ribbon(s, stroke.ink.width * scale);
  return polys.length === 0 ? [] : [{ primitive: { kind: "path", subpaths: polys }, fill, lineWidth: 1 }];
}
