# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2", "pillow>=10", "scipy>=1.13", "pypdfium2>=4.30"]
# ///
"""Import fidelity evaluation, stage 3: metrics, summary.json and report.html.

Reads what the two gated test stages wrote (see docs/import-notability.md,
"Fidelity evaluation"; run everything with scripts/import-eval.sh):

  <work>/oracle/<id8>/   thumbnails, our first-page renders, page1.pdf, meta.json
  <work>/canvas/<id8>/   per band: canvas snapshot, PKDrawing image, export PNG

and writes <out>/summary.json, <out>/report.html (self-contained) and the
report's images under <out>/img/. Nothing here reads note titles or text;
notes are named by the first 8 hex digits of their vault id.

    uv run scripts/import_eval.py --work data/eval/work --out data/eval
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import math
import statistics
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

PAGE_WIDTH = 612.0  # imported pages are letter width in points

# Ink classification, applied identically to both images of every pair.
DARK_LUM = 170  # luminance below this is ink (Notability's dot paper is >= 181)
CHROMA = 60  # max-min RGB above this is coloured ink or highlighter
PDF_DIFF = 60  # PDF notes: RGB distance from the PDF page (best of a 5x5 neighbourhood)
PDF_NOISE_FRACTION = 0.01  # PDF notes: a thumbnail differing from our PDF render in < 1 % of pixels shows no ink
LOW_RES_CORRELATION = 0.6  # darkness correlation needed when only a low-resolution thumbnail is current

# Flag thresholds (see docs/import-notability.md for the reasoning).
ORACLE_CHAMFER_PT = 1.5  # symmetric mean chamfer distance, points
ORACLE_F1 = 0.80  # 1-pixel-tolerant F1 at the largest thumbnail
ORACLE_RATIO = (0.6, 1.6)  # ink pixel ratio ours / Notability
ORACLE_EDGE_PT = 6.0  # any ink bounding-box edge
CANVAS_F1 = 0.90  # 1-pixel-tolerant F1, canvas vs export, per band
CANVAS_RATIO = (0.75, 1.33)  # ink pixel ratio canvas / export, per band (as CanvasHostRenderingTests)
CANVAS_EDGE_PT = 3.0
MIN_INK_PX = 30  # bands/thumbnails with fewer ink pixels on both sides are "empty"


# ---------------------------------------------------------------- images

def load_rgba(path: Path) -> np.ndarray:
    im = Image.open(path)
    if im.mode in ("I;16", "I;16B", "I"):
        im = im.point(lambda v: v / 256).convert("L")
    return np.asarray(im.convert("RGBA")).astype(np.float32)


def over(fg: np.ndarray, bg: np.ndarray) -> np.ndarray:
    """RGBA `fg` composited over RGB `bg` (same size) -> RGB float."""
    a = fg[..., 3:4] / 255.0
    return fg[..., :3] * a + bg * (1 - a)


def white(h: int, w: int) -> np.ndarray:
    return np.full((h, w, 3), 255.0, np.float32)


def fit(img: np.ndarray, h: int, w: int, fill: float) -> np.ndarray:
    """Crops or pads (top-left anchored) to h x w."""
    out = np.full((h, w) + img.shape[2:], fill, img.dtype)
    hh, ww = min(h, img.shape[0]), min(w, img.shape[1])
    out[:hh, :ww] = img[:hh, :ww]
    return out


def ink_mask(rgb: np.ndarray) -> np.ndarray:
    lum = rgb[..., 0] * 0.3 + rgb[..., 1] * 0.59 + rgb[..., 2] * 0.11
    chroma = rgb.max(axis=2) - rgb.min(axis=2)
    return (lum < DARK_LUM) | (chroma > CHROMA)


def pdf_ink_mask(rgb: np.ndarray, bg: np.ndarray) -> np.ndarray:
    """Pixels that differ from the PDF page by more than PDF_DIFF, allowing the
    page a two-pixel misregistration (the smallest distance to any background
    pixel in the 5x5 neighbourhood counts): Notability's own rasterization of
    the page is offset by about a pixel from pdfium's."""
    best = np.full(rgb.shape[:2], np.inf, np.float32)
    pad = np.pad(bg, ((2, 2), (2, 2), (0, 0)), mode="edge")
    h, w = rgb.shape[:2]
    for dy in range(5):
        for dx in range(5):
            d = np.sqrt(((rgb - pad[dy:dy + h, dx:dx + w]) ** 2).sum(axis=2))
            best = np.minimum(best, d)
    return best > PDF_DIFF


def render_pdf_page(path: Path, page: int, w: int, h: int) -> np.ndarray | None:
    try:
        import pypdfium2 as pdfium
    except ImportError:
        return None
    try:
        doc = pdfium.PdfDocument(str(path))
        p = doc[max(page - 1, 0)]
        pw, ph = p.get_size()
        bm = p.render(scale=w / pw, fill_color=(255, 255, 255, 255))
        im = bm.to_pil().convert("RGB")
        # Notability lays the page out at the document width; height follows its aspect.
        im = im.resize((w, max(1, round(w * ph / pw))), Image.LANCZOS)
        arr = np.asarray(im).astype(np.float32)
        return fit(arr, h, w, 255.0)
    except Exception as e:  # a broken PDF is reported, not fatal
        print(f"warning: PDF render failed: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------- metrics

def compare(a: np.ndarray, b: np.ndarray, pt_per_px: float, search: int = 0) -> dict:
    """Metrics of mask `a` (ours / canvas) against `b` (reference)."""
    na, nb = int(a.sum()), int(b.sum())
    m: dict = {"inkA": na, "inkB": nb}
    if na < MIN_INK_PX and nb < MIN_INK_PX:
        m["empty"] = True
        return m
    m["ratio"] = na / nb if nb else math.inf
    inter = int((a & b).sum())
    union = int((a | b).sum())
    m["iou"] = inter / union if union else 1.0
    st = np.ones((3, 3), bool)
    da, db = ndimage.binary_dilation(a, st), ndimage.binary_dilation(b, st)
    prec = float((a & db).sum() / na) if na else 0.0
    rec = float((b & da).sum() / nb) if nb else 0.0
    m["precision1"], m["recall1"] = prec, rec
    m["f1"] = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    if na and nb:
        dtb = ndimage.distance_transform_edt(~b) * pt_per_px
        dta = ndimage.distance_transform_edt(~a) * pt_per_px
        ab, ba = dtb[a], dta[b]
        m["chamfer"] = float((ab.mean() + ba.mean()) / 2)
        m["chamferAB"], m["chamferBA"] = float(ab.mean()), float(ba.mean())
        m["chamfer95"] = float(max(np.percentile(ab, 95), np.percentile(ba, 95)))
        ya, xa = np.nonzero(a)
        yb, xb = np.nonzero(b)
        m["edges"] = [float((xa.min() - xb.min()) * pt_per_px), float((ya.min() - yb.min()) * pt_per_px),
                      float((xa.max() - xb.max()) * pt_per_px), float((ya.max() - yb.max()) * pt_per_px)]
    else:
        m["chamfer"] = math.inf
    if search and na and nb:
        best = (m["iou"], 0, 0)
        for dy in range(-search, search + 1):
            for dx in range(-search, search + 1):
                s = np.roll(np.roll(a, dy, 0), dx, 1)
                u = (s | b).sum()
                iou = (s & b).sum() / u if u else 0
                if iou > best[0] + 1e-9:
                    best = (float(iou), dx, dy)
        m["bestShiftIoU"], m["residualOffset"] = best[0], [best[1] * pt_per_px, best[2] * pt_per_px]
    return m


def clean(o):
    """JSON-safe: infinities and NaN become null."""
    if isinstance(o, float):
        return o if math.isfinite(o) else None
    if isinstance(o, dict):
        return {k: clean(v) for k, v in o.items()}
    if isinstance(o, list):
        return [clean(v) for v in o]
    return o


# ---------------------------------------------------------------- stage: oracle

def darkness(rgb: np.ndarray, bg: np.ndarray | None) -> np.ndarray:
    """Per-pixel ink strength: distance from the background (white or the PDF page)."""
    if bg is None:
        return 255 - (rgb[..., 0] * 0.3 + rgb[..., 1] * 0.59 + rgb[..., 2] * 0.11)
    return np.sqrt(((rgb - bg) ** 2).sum(axis=2))


def correlation(a: np.ndarray, b: np.ndarray) -> float | None:
    """Pearson correlation of two darkness maps, each blurred by one pixel
    (sub-pixel tolerance); meaningful at every thumbnail size."""
    a = ndimage.gaussian_filter(a, 1.0).ravel()
    b = ndimage.gaussian_filter(b, 1.0).ravel()
    if a.std() < 1e-6 or b.std() < 1e-6:
        return None
    return float(np.corrcoef(a, b)[0, 1])


LOW_RES = 288  # thumbnails narrower than this (thumb, 2x, 3x) are too coarse for mask metrics


def oracle_note(d: Path) -> tuple[dict, dict]:
    meta = json.loads((d / "meta.json").read_text())
    res: dict = {"thumbs": {}}
    pdf = meta.get("pdf")
    per_thumb_images: dict = {}
    for t in sorted(meta["thumbs"], key=lambda t: -t["width"]):
        name, w, h = t["name"], t["width"], t["height"]
        ours_path = d / ("ours-" + name)
        if not ours_path.exists():
            continue
        thumb_rgb = over(fit(load_rgba(d / name), h, w, 255.0), white(h, w))
        ours = fit(load_rgba(ours_path), h, w, 0.0)
        bg = None
        method = "paper"
        if pdf and (d / "page1.pdf").exists():
            bg = render_pdf_page(d / "page1.pdf", pdf.get("page", 1), w, h)
            if bg is None:
                method = "paper (PDF not rendered)"
        if bg is not None:
            method = "pdf-diff"
            ours_rgb = over(ours, bg)
            a, b = pdf_ink_mask(ours_rgb, bg), pdf_ink_mask(thumb_rgb, bg)
        else:
            ours_rgb = over(ours, white(h, w))
            a, b = ink_mask(ours_rgb), ink_mask(thumb_rgb)
        pt = PAGE_WIDTH / w
        m = compare(a, b, pt, search=4 if w >= LOW_RES else 0)
        m["method"], m["size"] = method, [w, h]
        m["darknessCorrelation"] = correlation(darkness(ours_rgb, bg), darkness(thumb_rgb, bg))
        m["inkFractionB"] = m["inkB"] / (w * h)
        res["thumbs"][name] = m
        per_thumb_images[name] = {"ours": ours_rgb, "thumb": thumb_rgb, "a": a, "b": b}
    names = list(res["thumbs"])  # largest first
    if not names:
        return meta, res | {"_images": {}}
    # The primary thumbnail is the largest one that shows ink, preferring
    # full-resolution ones: Notability leaves some sizes stale (blank paper)
    # while others are current.
    shows = [n for n in names if res["thumbs"][n]["inkB"] >= MIN_INK_PX]
    hires = [n for n in shows if res["thumbs"][n]["size"][0] >= LOW_RES]
    res["primary"] = (hires or shows or names)[0]
    res["lowResOnly"] = not hires and bool(shows)
    res["staleThumbs"] = [n for n in names if res["thumbs"][n]["inkB"] < MIN_INK_PX <= res["thumbs"][n]["inkA"]]
    return meta, res | {"_images": per_thumb_images[res["primary"]]}


# ---------------------------------------------------------------- stage: canvas

def canvas_note(d: Path) -> dict:
    info = json.loads((d / "bands.json").read_text())
    bands = []
    worst_img = None
    worst_key = None
    for band in info["bands"]:
        n = band["name"]
        ex = load_rgba(d / f"{n}-export.png")
        cv = load_rgba(d / f"{n}-canvas.png")
        pk = load_rgba(d / f"{n}-pk.png")
        h, w = min(ex.shape[0], cv.shape[0], pk.shape[0]), min(ex.shape[1], cv.shape[1], pk.shape[1])
        # The canvas snapshot's last pixel row can be the host background (a
        # fractional band height): drop it from every image.
        h -= 1
        ex_rgb = over(ex[:h, :w], white(h, w))
        cv_rgb = over(cv[:h, :w], white(h, w))
        pk_rgb = over(pk[:h, :w], white(h, w))
        e, c, p = ink_mask(ex_rgb), ink_mask(cv_rgb), ink_mask(pk_rgb)
        pt = PAGE_WIDTH / w
        m = {"band": band["band"], "page": band["page"],
             "canvasShift": band["canvasTop"] - band["top"],
             "canvas": compare(c, e, pt), "pk": compare(p, e, pt), "canvasVsPk": compare(c, p, pt)}
        bands.append(m)
        cm = m["canvas"]
        if not cm.get("empty"):
            key = cm.get("f1", 0)
            if worst_key is None or key < worst_key:
                worst_key = key
                worst_img = {"canvas": cv_rgb, "export": ex_rgb, "a": c, "b": e, "band": band["band"]}
    return {"bands": bands, "_images": worst_img}


# ---------------------------------------------------------------- flags

def oracle_flags(meta: dict, res: dict) -> list[str]:
    """Flags for the oracle comparison. Content the importer cannot carry is
    flagged by kind (`has-media`, `pdf-template`) so outliers explain
    themselves; geometry flags are `oracle-*`."""
    flags = []
    if meta.get("media"):
        flags.append("has-media")
    if (meta.get("paperIdentifier") or "").startswith("TemplatePDF"):
        flags.append("pdf-template")
    if not res["thumbs"]:
        return flags + ["no-thumbnail"]
    m = res["thumbs"][res["primary"]]
    if res.get("staleThumbs"):
        flags.append("stale-thumbnails")
    if m["inkB"] < MIN_INK_PX and m["inkA"] < MIN_INK_PX:
        return flags  # nothing on page 1 on either side: consistent
    if m["inkB"] < MIN_INK_PX:
        return flags + ["thumbnails-all-blank"]  # every thumbnail stale
    if m["inkA"] < MIN_INK_PX:
        # Notability shows something on page 1 that we have no ink for.
        if meta["strokesOnPage1"] == 0 and m["inkFractionB"] < PDF_NOISE_FRACTION and m["method"] == "pdf-diff":
            return flags  # PDF rasterization noise only
        return flags + ["thumbnail-content-not-imported"]
    if res.get("lowResOnly"):
        flags.append("low-res-thumbnail-only")
        c = m.get("darknessCorrelation")
        if c is None or c < LOW_RES_CORRELATION:
            flags.append("oracle-correlation")
        return flags
    if (m.get("chamfer") or math.inf) > ORACLE_CHAMFER_PT:
        flags.append("oracle-chamfer")
    if m.get("f1", 0) < ORACLE_F1:
        flags.append("oracle-f1")
    r = m.get("ratio", 0)
    if not (ORACLE_RATIO[0] <= r <= ORACLE_RATIO[1]):
        flags.append("oracle-ratio")
    if any(abs(e) > ORACLE_EDGE_PT for e in m.get("edges", [])):
        flags.append("oracle-bbox")
    return flags


INFO_FLAGS = {"stale-thumbnails", "has-media", "pdf-template", "low-res-thumbnail-only"}  # context, not failures


def categorize(row: dict, flags: list[str]) -> str:
    """A first guess at the root cause of a flagged note, from its flags and
    content; the report's investigation section confirms or corrects it."""
    failing = [f for f in flags if f not in INFO_FLAGS]
    if not failing:
        return ""
    if any(f.startswith("canvas-") for f in failing):
        return "canvas conversion"
    if "thumbnails-all-blank" in failing:
        return "stale thumbnail"
    if "thumbnail-content-not-imported" in failing and row["strokesOnPage1"] == 0 and row["pdfPages"]:
        return "PDF page raster differs (no ink on page 1)"
    o = row.get("oracle") or {}
    if set(failing) <= {"oracle-bbox"} and (o.get("f1") or 0) >= 0.95 and (o.get("chamfer") or 9) <= 0.5:
        # Shapes agree; one faint stroke end sits on either side of the mask threshold.
        return "measurement: faint ink at the mask threshold"
    if "has-media" in flags:
        return "unsupported: images"
    if "pdf-template" in flags:
        return "unsupported: PDF template paper"
    if "stale-thumbnails" in flags or "low-res-thumbnail-only" in failing:
        return "stale thumbnail (suspected)"
    return "importer geometry (suspected)"


def canvas_flags(c: dict) -> list[str]:
    flags = set()
    for b in c["bands"]:
        m = b["canvas"]
        if m.get("empty"):
            continue
        if m.get("f1", 0) < CANVAS_F1:
            flags.add("canvas-f1")
        r = m.get("ratio", 0)
        if not (CANVAS_RATIO[0] <= r <= CANVAS_RATIO[1]):
            flags.add("canvas-ratio")
        if any(abs(e) > CANVAS_EDGE_PT for e in m.get("edges", [])):
            flags.add("canvas-bbox")
        if abs(b["canvasShift"]) > 0.5:
            flags.add("canvas-scroll")
    return sorted(flags)


# ---------------------------------------------------------------- report

def png_data_uri(rgb: np.ndarray, max_w: int = 420) -> str:
    im = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))
    if im.width > max_w:
        im = im.resize((max_w, max(1, round(im.height * max_w / im.width))), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def overlay(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Ours/canvas only: red; reference only: blue; both: black."""
    out = white(*a.shape)
    out[a & ~b] = (220, 40, 40)
    out[b & ~a] = (40, 90, 230)
    out[a & b] = (20, 20, 20)
    return out


def fmt(v, nd=2):
    if v is None:
        return "–"
    if isinstance(v, float):
        if not math.isfinite(v):
            return "∞"
        return f"{v:.{nd}f}"
    return str(v)


def pct(values, q):
    v = sorted(x for x in values if x is not None and math.isfinite(x))
    if not v:
        return None
    k = (len(v) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def dist(values) -> dict:
    v = [x for x in values if x is not None and math.isfinite(x)]
    if not v:
        return {"n": 0}
    return {"n": len(v), "min": min(v), "p10": pct(v, 0.1), "median": statistics.median(v), "mean": statistics.fmean(v),
            "p90": pct(v, 0.9), "max": max(v)}


def histogram(values, edges) -> list[int]:
    v = [x for x in values if x is not None and math.isfinite(x)]
    counts = [0] * (len(edges) - 1)
    for x in v:
        for i in range(len(edges) - 1):
            if edges[i] <= x < edges[i + 1] or (i == len(edges) - 2 and x == edges[-1]):
                counts[i] += 1
                break
    return counts


CSS = """
:root{--bg:#fbfbfa;--fg:#1d1d1f;--mut:#6b6b70;--line:#e2e2e0;--bad:#b3261e;--warn:#9a6700;--ok:#1a7f37;--card:#fff}
@media (prefers-color-scheme: dark){:root{--bg:#161618;--fg:#ececee;--mut:#9b9ba0;--line:#2c2c30;--bad:#ff8a80;--warn:#e3b341;--ok:#56d364;--card:#1f1f22}}
body{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:1280px;margin:auto}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px}p,li{color:var(--fg)}.mut{color:var(--mut)}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums;font-size:12.5px}
th,td{border-bottom:1px solid var(--line);padding:4px 6px;text-align:right;white-space:nowrap}th{position:sticky;top:0;background:var(--bg)}
td:first-child,th:first-child,td.l,th.l{text-align:left}.bad{color:var(--bad);font-weight:600}.warn{color:var(--warn)}
.wrap{overflow-x:auto}.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin:12px 0}
.imgs{display:flex;gap:8px;flex-wrap:wrap}.imgs figure{margin:0}.imgs img{border:1px solid var(--line);background:#fff;max-width:100%;image-rendering:auto}
figcaption{font-size:11.5px;color:var(--mut)}code{font-size:12px}.kv{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:6px 18px}
"""


def write_report(out: Path, summary: dict, rows: list[dict], gallery: list[dict]) -> None:
    agg = summary["aggregate"]
    th = summary["thresholds"]
    h = ["<!doctype html><html lang=en><head><meta charset=utf-8>",
         "<meta name=viewport content='width=device-width,initial-scale=1'>",
         "<title>Import fidelity</title><style>", CSS, "</style></head><body>",
         "<h1>Notability import fidelity</h1>",
         f"<p class=mut>{summary['generated']} · {agg['notes']} imported notes · {agg['bands']} canvas bands. "
         "Local report: notes are named by the first 8 hex digits of their vault id.</p>"]
    h.append("<h2>Aggregate</h2><div class='card kv'>")
    for k, v in agg["display"].items():
        h.append(f"<div><span class=mut>{k}</span><br><b>{v}</b></div>")
    h.append("</div>")
    h.append("<h2>Root-cause categories (flagged notes)</h2><div class=card><ul>")
    for k, v in agg["categories"].items():
        h.append(f"<li>{k}: {v}</li>")
    h.append("</ul></div>")
    h.append("<h2>Flags</h2><div class=card><ul>")
    for k, v in sorted(agg["flagCounts"].items(), key=lambda kv: -kv[1]):
        h.append(f"<li><code>{k}</code>: {v}</li>")
    h.append("</ul><p class=mut>Thresholds: " + ", ".join(f"{k} {v}" for k, v in th.items()) + "</p></div>")
    if agg.get("histograms"):
        h.append("<h2>Distributions</h2><div class=card>")
        for name, hist in agg["histograms"].items():
            h.append(f"<p><b>{name}</b><br><code>")
            for label, n in hist:
                h.append(f"{label}: {'█' * n} {n}<br>")
            h.append("</code></p>")
        h.append("</div>")
    h.append("<h2>Per note (worst first)</h2><div class=wrap><table><tr>"
             "<th class=l>note</th><th>pages</th><th>strokes</th><th>PDF</th><th>thumb</th><th>method</th>"
             "<th>IoU</th><th>F1±1px</th><th>chamfer pt</th><th>ratio</th><th>max edge pt</th><th>offset pt</th>"
             "<th>canvas F1 min</th><th>canvas F1 med</th><th>canvas IoU min</th><th>canvas IoU med</th>"
             "<th>canvas ratio range</th><th class=l>category</th><th class=l>flags</th></tr>")
    for r in rows:
        o = r.get("oracle") or {}
        c = r.get("canvasSummary") or {}
        cls = "bad" if r["failing"] else ""
        off = o.get("residualOffset")
        h.append(
            f"<tr><td><a href='#n{r['id8']}'>{r['id8']}</a></td><td>{r['bands']}</td><td>{r['strokes']}</td>"
            f"<td>{r['pdfPages'] or ''}</td><td>{o.get('thumb', '–')}</td><td class=l>{o.get('method', '')}</td>"
            f"<td>{fmt(o.get('iou'))}</td><td>{fmt(o.get('f1'))}</td><td>{fmt(o.get('chamfer'))}</td>"
            f"<td>{fmt(o.get('ratio'))}</td><td>{fmt(o.get('maxEdge'), 1)}</td>"
            f"<td>{fmt(off[0], 1) + ', ' + fmt(off[1], 1) if off else '–'}</td>"
            f"<td>{fmt(c.get('f1Min'))}</td><td>{fmt(c.get('f1Median'))}</td>"
            f"<td>{fmt(c.get('iouMin'))}</td><td>{fmt(c.get('iouMedian'))}</td>"
            f"<td>{fmt(c.get('ratioMin'))}–{fmt(c.get('ratioMax'))}</td>"
            f"<td class='l {cls}'>{r['category']}</td><td class=l>{' '.join(r['flags'])}</td></tr>")
    h.append("</table></div>")
    h.append("<h2>Images: worst and flagged notes</h2><p class=mut>Overlay: red = ours / canvas only, "
             "blue = Notability / export only, black = both.</p>")
    for g in gallery:
        h.append(f"<div class=card id='n{g['id8']}'><b>{g['id8']}</b> <span class=mut>{' '.join(g['flags'])}</span>")
        for title, figs in g["sets"]:
            h.append(f"<p class=mut>{title}</p><div class=imgs>")
            for cap, uri in figs:
                h.append(f"<figure><img src='{uri}' alt='{cap}'><figcaption>{cap}</figcaption></figure>")
            h.append("</div>")
        h.append("</div>")
    h.append("</body></html>")
    (out / "report.html").write_text("".join(h))


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--gallery", type=int, default=20, help="worst notes to show images for (plus every flagged one)")
    args = ap.parse_args()
    oracle_dir, canvas_dir = args.work / "oracle", args.work / "canvas"
    if not oracle_dir.is_dir():
        print(f"no {oracle_dir}: run the oracle stage first", file=sys.stderr)
        return 2
    import_report = json.loads((args.work / "import.json").read_text()) if (args.work / "import.json").exists() else {}

    rows, images = [], {}
    notes = sorted(p for p in oracle_dir.iterdir() if (p / "meta.json").exists())
    for i, d in enumerate(notes):
        id8 = d.name
        meta, ores = oracle_note(d)
        oimg = ores.pop("_images")
        row = {"id8": id8, "strokes": meta["strokes"], "markers": meta["markers"], "dashed": meta["dashed"],
               "pdfPages": meta["pdfPages"], "media": meta["media"], "bands": meta["bands"],
               "strokesOnPage1": meta["strokesOnPage1"], "formatVersion": meta["formatVersion"],
               "documentWidth": meta["documentWidth"], "oracleThumbs": ores["thumbs"]}
        flags = oracle_flags(meta, ores)
        if ores["thumbs"]:
            name = ores["primary"]
            m = ores["thumbs"][name]
            row["staleThumbs"] = ores["staleThumbs"]
            row["oracle"] = {"thumb": name, "method": m.get("method"), "iou": m.get("iou"), "f1": m.get("f1"),
                             "chamfer": m.get("chamfer"), "chamfer95": m.get("chamfer95"), "ratio": m.get("ratio"),
                             "edges": m.get("edges"), "maxEdge": max((abs(e) for e in m.get("edges", [])), default=None),
                             "residualOffset": m.get("residualOffset"), "bestShiftIoU": m.get("bestShiftIoU"),
                             "empty": m.get("empty", False), "lowResOnly": ores.get("lowResOnly", False),
                             "darknessCorrelation": m.get("darknessCorrelation")}
        cimg = None
        if (canvas_dir / id8 / "bands.json").exists():
            c = canvas_note(canvas_dir / id8)
            cimg = c.pop("_images")
            row["canvasBands"] = c["bands"]
            inked = [b["canvas"] for b in c["bands"] if not b["canvas"].get("empty")]
            pk = [b["pk"] for b in c["bands"] if not b["pk"].get("empty")]
            row["canvasSummary"] = {
                "bands": len(c["bands"]), "inkedBands": len(inked),
                "iouMin": min((m["iou"] for m in inked), default=None),
                "iouMedian": statistics.median([m["iou"] for m in inked]) if inked else None,
                "f1Min": min((m["f1"] for m in inked), default=None),
                "f1Median": statistics.median([m["f1"] for m in inked]) if inked else None,
                "ratioMin": min((m["ratio"] for m in inked), default=None),
                "ratioMax": max((m["ratio"] for m in inked), default=None),
                "chamferMax": max((m.get("chamfer", 0) for m in inked), default=None),
                "pkF1Min": min((m["f1"] for m in pk), default=None),
            }
            flags += canvas_flags(c)
        else:
            flags.append("canvas-missing")
        row["flags"] = flags
        # Worst-first: flagged notes, then by the lower of oracle F1 and canvas F1 min.
        of1 = (row.get("oracle") or {}).get("f1")
        cf1 = (row.get("canvasSummary") or {}).get("f1Min")
        score = min([v for v in (of1, cf1) if v is not None] or [1.0])
        row["failing"] = [f for f in flags if f not in INFO_FLAGS]
        row["category"] = categorize(row, flags)
        row["_score"] = (0 if row["failing"] else 1, score)
        rows.append(row)
        images[id8] = (oimg, cimg)
        print(f"[{i + 1}/{len(notes)}] {id8} {' '.join(flags)}", file=sys.stderr)

    rows.sort(key=lambda r: r["_score"])
    for r in rows:
        r.pop("_score")

    # Aggregates over notes with ink on both sides of the oracle.
    def has_ink_both(r):
        m = r["oracleThumbs"].get(r["oracle"]["thumb"], {})
        return m.get("inkA", 0) >= MIN_INK_PX and m.get("inkB", 0) >= MIN_INK_PX

    scored = [r for r in rows if r.get("oracle") and has_ink_both(r) and not r["oracle"]["lowResOnly"]]
    paper = [r for r in scored if not r["pdfPages"]]
    pdfs = [r for r in scored if r["pdfPages"]]
    bands = [b for r in rows for b in r.get("canvasBands", [])]
    inked_bands = [b["canvas"] for b in bands if not b["canvas"].get("empty")]
    flag_counts: dict[str, int] = {}
    for r in rows:
        for f in r["flags"]:
            flag_counts[f] = flag_counts.get(f, 0) + 1
    agg = {
        "notes": len(rows), "import": import_report, "oracleScored": len(scored),
        "oracleScoredPaper": len(paper), "oracleScoredPDF": len(pdfs),
        "oracleIoU": dist([r["oracle"]["iou"] for r in scored]),
        "oracleF1": dist([r["oracle"]["f1"] for r in scored]),
        "oracleChamfer": dist([r["oracle"]["chamfer"] for r in scored]),
        "oracleRatio": dist([r["oracle"]["ratio"] for r in scored]),
        "oracleMaxEdge": dist([r["oracle"]["maxEdge"] for r in scored]),
        "oracleF1Paper": dist([r["oracle"]["f1"] for r in paper]),
        "oracleF1PDF": dist([r["oracle"]["f1"] for r in pdfs]),
        "oracleChamferPaper": dist([r["oracle"]["chamfer"] for r in paper]),
        "oracleChamferPDF": dist([r["oracle"]["chamfer"] for r in pdfs]),
        "bands": len(bands), "inkedBands": len(inked_bands),
        "canvasIoU": dist([m["iou"] for m in inked_bands]),
        "canvasF1": dist([m["f1"] for m in inked_bands]),
        "canvasRatio": dist([m["ratio"] for m in inked_bands]),
        "canvasChamfer": dist([m.get("chamfer") for m in inked_bands]),
        "pkF1": dist([b["pk"]["f1"] for b in bands if not b["pk"].get("empty")]),
        "canvasVsPkF1": dist([b["canvasVsPk"]["f1"] for b in bands if not b["canvasVsPk"].get("empty")]),
        "flagCounts": flag_counts,
        "flaggedNotes": sum(1 for r in rows if r["failing"]),
        "categories": {c: sum(1 for r in rows if r["category"] == c) for c in sorted({r["category"] for r in rows if r["category"]})},
    }

    def d(x, nd=3):
        return "–" if not x.get("n") else f"{x['median']:.{nd}f} (p10 {x['p10']:.{nd}f}, min {x['min']:.{nd}f})"

    agg["display"] = {
        "notes imported / skipped / failed": f"{import_report.get('imported', '?')} / {import_report.get('skipped', '?')} / {import_report.get('failed', '?')}",
        "oracle-scored notes (paper / PDF)": f"{len(scored)} ({len(paper)} / {len(pdfs)})",
        "oracle F1±1px median": d(agg["oracleF1"]),
        "oracle IoU median": d(agg["oracleIoU"]),
        "oracle chamfer pt median": "–" if not agg["oracleChamfer"].get("n") else
        f"{agg['oracleChamfer']['median']:.2f} (p90 {agg['oracleChamfer']['p90']:.2f}, max {agg['oracleChamfer']['max']:.2f})",
        "oracle ink ratio median": d(agg["oracleRatio"]),
        "canvas bands (inked)": f"{len(bands)} ({len(inked_bands)})",
        "canvas vs export F1±1px": d(agg["canvasF1"]),
        "canvas vs export IoU": d(agg["canvasIoU"]),
        "canvas / export ink ratio": "–" if not agg["canvasRatio"].get("n") else
        f"{agg['canvasRatio']['median']:.3f} ({agg['canvasRatio']['min']:.3f}–{agg['canvasRatio']['max']:.3f})",
        "PKDrawing.image vs export F1": d(agg["pkF1"]),
        "canvas vs PKDrawing.image F1": d(agg["canvasVsPkF1"]),
        "flagged notes": str(agg["flaggedNotes"]),
    }
    edges = [0, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95, 1.0001]
    agg["histograms"] = {
        "oracle F1±1px (notes)": [(f"{edges[i]:.2f}–{min(edges[i + 1], 1):.2f}", n)
                                  for i, n in enumerate(histogram([r["oracle"]["f1"] for r in scored], edges))],
        "canvas vs export F1±1px (bands)": [(f"{edges[i]:.2f}–{min(edges[i + 1], 1):.2f}", n)
                                            for i, n in enumerate(histogram([m["f1"] for m in inked_bands], edges))],
    }
    ch_edges = [0, 0.25, 0.5, 0.75, 1, 1.5, 2, 4, 1e9]
    agg["histograms"]["oracle chamfer pt (notes)"] = [
        (f"{ch_edges[i]}–{ch_edges[i + 1] if ch_edges[i + 1] < 1e9 else '∞'}", n)
        for i, n in enumerate(histogram([r["oracle"]["chamfer"] for r in scored], ch_edges))]

    thresholds = {"oracle chamfer pt": ORACLE_CHAMFER_PT, "oracle F1": ORACLE_F1, "oracle ratio": ORACLE_RATIO,
                  "oracle edge pt": ORACLE_EDGE_PT, "canvas F1": CANVAS_F1, "canvas ratio": CANVAS_RATIO,
                  "canvas edge pt": CANVAS_EDGE_PT, "ink: lum <": DARK_LUM, "ink: chroma >": CHROMA,
                  "PDF diff >": PDF_DIFF, "empty below px": MIN_INK_PX}
    import datetime
    summary = {"generated": datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z"),
               "thresholds": {k: list(v) if isinstance(v, tuple) else v for k, v in thresholds.items()},
               "aggregate": agg, "notes": rows}
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "summary.json").write_text(json.dumps(clean(summary), indent=1))

    # Gallery: the worst N plus every flagged note.
    img_dir = args.out / "img"
    img_dir.mkdir(exist_ok=True)
    pick = [r for r in rows if r["failing"]]
    for r in rows[: args.gallery]:
        if r not in pick:
            pick.append(r)
    gallery = []
    for r in pick:
        oimg, cimg = images[r["id8"]]
        sets = []
        if oimg:
            figs = [("ours (InkRender, page 1)", oimg["ours"]), ("Notability thumbnail", oimg["thumb"]),
                    ("overlay of ink masks", overlay(oimg["a"], oimg["b"]))]
            for k, (cap, arr) in enumerate(figs):
                Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).save(img_dir / f"{r['id8']}-oracle-{k}.png")
            sets.append(("Import vs Notability thumbnail", [(c, png_data_uri(a)) for c, a in figs]))
        if cimg:
            figs = [(f"canvas, band {cimg['band']}", cimg["canvas"]), ("export (InkRender)", cimg["export"]),
                    ("overlay of ink masks", overlay(cimg["a"], cimg["b"]))]
            for k, (cap, arr) in enumerate(figs):
                Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).save(img_dir / f"{r['id8']}-canvas-{k}.png")
            sets.append(("Canvas vs export (worst band)", [(c, png_data_uri(a)) for c, a in figs]))
        gallery.append({"id8": r["id8"], "flags": r["flags"], "sets": sets})
    write_report(args.out, summary, rows, gallery)
    print(json.dumps(clean(agg["display"]), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
