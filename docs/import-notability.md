# Importing from Notability

`Sources/InkImport` reads Notability's `.note` packages and writes them into
a vault as ordinary notes. Notability's format is undocumented; everything
below was reverse-engineered from a real backup of 130 notes written by
Notability 10.2 through 14.9 (session format versions 5 to 9) and checked
against the thumbnails Notability stores in each package. Where a rule is
empirical it says so.

## Running a bulk import

Library call (the CLI command will wrap it):

```swift
var clock = HybridClock()
let report = try NotabilityImporter.import(
    paths: [URL(fileURLWithPath: "Notability-backup.zip")],
    into: vault, device: device, clock: &clock,
    options: .init(overwrite: false, notebook: nil, scaleToLetterWidth: true))
for n in report.notes { print(n.status, n.source, n.strokes, n.dropped) }
```

Each path may be a single `.note` (a zip, or an unzipped package directory),
a directory (searched recursively, not descending into packages), or
the zip Notability's Google Drive backup produces (`Notability/<Subject>/
<Folder>/<name>.note`, plus PDFs that are ignored). Each note becomes one
delta: `addPage`, one `addStroke` per stroke, `setMeta` for title, tags,
notebook, paper and page size, and `setPageRecognition`.

- **Notebook**: the directories under `Notability/` (`Research/Daily log`);
  for a directory input without one, the path relative to it; otherwise
  Notability's subject. `options.notebook` overrides all of these.
- **Idempotent**: the note id is `UUID.derived(from: "inkvault-notability:"
  + uuidKey)` (SHA-256, RFC 9562 version 8). A note already in the vault is
  skipped; `overwrite` removes its pages and writes the content again with
  fresh page and stroke ids salted with the overwriting delta's
  `<device>-<seq>`, so no overwrite from any device re-mints a removed
  (tombstoned) id (`format.md` §5.2). Tags and notebook are always written,
  so an overwrite can clear them.
  Two packages with the same `uuidKey` in one run (Notability "copies" made
  by duplicating the file) import once; the second is reported as skipped.
- **Created date**: the delta's `wall` is Notability's creation date, so the
  note's `created` (`format.md` §5.4) is preserved. Its `hlc` is current.
- **Scale**: by default (`scaleToLetterWidth`) every length (coordinates,
  widths, paper pitch, recognition boxes, break height) is multiplied by
  `612 / W`, so a page is US-letter width in points and exports paginate as
  letter-width pages (612 × 803.25 for Notability's 21/16 page). Off keeps
  Notability's document units.
- **Report**: per note `ok`, `skipped(reason)` or `failed(reason)`, stroke
  count, recognised pages, Notability's original document width, and what
  was dropped. A corrupt note (bad zip, inconsistent arrays, coordinates
  beyond ±10⁶) fails with a reason and never stops the run.

Real-data checks live in `Tests/InkImportTests/RealNotabilityTests.swift`
and are skipped unless `INKVAULT_NOTABILITY_SAMPLES` points at a backup zip
or directory:

```bash
INKVAULT_NOTABILITY_SAMPLES=data/Notability-backup.zip \
INKVAULT_NOTABILITY_RENDER_DIR=data/render \
  swift test --filter RealNotabilityTests            # parse all, render + compare, page geometry
INKVAULT_NOTABILITY_SAMPLES=data/Notability-backup.zip \
INKVAULT_NOTABILITY_BULK_VAULT=data/scratch.inkvault \
  swift test --filter testBulkImport                 # full import, prints report
```

## Fidelity evaluation

A repeatable, exhaustive check of every imported note against Notability's
own rendering, and of the app's canvas against the export, to re-run after
any importer, renderer or canvas change:

```bash
scripts/import-eval.sh data/Notability-backup.zip      # writes data/eval/report.html, summary.json
```

It needs macOS, Xcode with an iPadOS 26+ simulator (`INKVAULT_SIM_ID`
picks one; use an iPadOS 26.x one, the user's iPad cannot run 27) and `uv`.
The output directory (default `data/eval`, git-ignored) must be ignored by
git, since everything in it is derived from personal notes; the script
refuses otherwise. Notes are named only by the first 8 hex digits of their
vault id (a hash of Notability's uuid). Three stages:

1. **Import oracle** (`ImportFidelityEvalTests`, gated on
   `INKVAULT_NOTABILITY_SAMPLES` and `INKVAULT_EVAL_DIR`): imports the backup
   into a fresh scratch vault (`work/vault.inkvault`, new key
   `work/identity.key`) with the normal importer, reads every note back from
   the vault, and renders its first Notability page (`PNGWriter`, no paper,
   one `breakHeight` tall) at the width of each thumbnail in the package
   (`thumb.png` 48 px … `thumb12x.png` 576 px), so the known geometry aligns
   the two images with no search: 612 pt ↔ thumbnail width, y from the top.
   It also copies the thumbnails and, for notes made from a PDF, the PDF and
   the page number of the note's first page (`pageLayoutArray`).
2. **Canvas vs export** (`CanvasExportEvalTests` in the app tests, gated on
   `INKVAULT_EVAL_VAULT`, `INKVAULT_EVAL_IDENTITY`, `INKVAULT_EVAL_OUT`, passed
   as `TEST_RUNNER_…` to `xcodebuild test`): for every band (export page,
   one `breakHeight`) of every page of every note, including every band of
   tall infinite pages, an on-screen snapshot of a `PageCanvasHost` showing
   `NoteEditor.drawing(for:)` (Stroke → PKStroke → PKDrawing, what the editor
   displays) in a window one band in size at fit-width zoom 1, scrolled to the
   band; `PKDrawing.image` of the same rect; and `PNGWriter`'s page for the band.
   The canvas page is extended to whole bands so the last band scrolls to the
   top like the others. About 3 s per band plus about 20 s per note (PencilKit tiles settle for
   `INKVAULT_EVAL_SETTLE_MS`, default 1200).
3. **Metrics and report** (`scripts/import_eval.py`, run with `uv`): writes
   `summary.json` (every metric per thumbnail and per band, aggregates,
   thresholds) and a self-contained `report.html` (per-note table worst
   first, distributions, and ours / reference / overlay images for the worst
   20 notes and every flagged one, also saved under `img/`).

**Ink masks.** Both images of a pair go through the same classifier. On
paper, a pixel is ink when its luminance is below 170 (Notability's dot paper
is 181 and lighter) or its chroma (max − min of RGB) is above 60 (coloured ink
and highlighter); our renders are composited on white first. On a PDF page the
reference is the PDF page rendered with pdfium at the thumbnail size, and a
pixel is ink when its RGB distance from the page exceeds 60 for every page
pixel in its 5 × 5 neighbourhood: Notability's own raster of the page is about
a pixel off pdfium's, and without that tolerance page edges show up as ink.
Our render is composited on the same PDF raster, so both sides are judged the
same way. A thumbnail that differs from our PDF raster in under 1 % of its
pixels counts as showing no ink.

**Metrics** (oracle: our page 1 vs each thumbnail; canvas: canvas vs export
per band, plus `PKDrawing.image` vs export and canvas vs `PKDrawing.image`):
ink pixel ratio, IoU, F1 with one pixel of tolerance (precision: our ink
pixels within a pixel of reference ink; recall the other way), symmetric mean
chamfer distance in points (and the larger 95th percentile), ink bounding-box
edge deltas in points, and, for thumbnails at least 288 px wide, the integer
pixel shift within ±4 px that maximises IoU (the residual offset; zero means
the geometry needs no correction). A darkness correlation (Pearson, after a
one-pixel blur) covers the low-resolution thumbnails, where thin ink is too
faint for a mask.

**Which thumbnail.** Notability leaves some thumbnail sizes stale: blank
paper, or an older state of the page, while other sizes are current. The
primary thumbnail is the largest one at least 288 px wide that shows ink;
sizes that are blank where we have ink are listed as stale. A note whose only
current thumbnails are low resolution is judged by darkness correlation.

**Flags.** Oracle: chamfer > 1.5 pt, F1 < 0.80, ink ratio outside 0.6–1.6, an
ink bounding-box edge off by > 6 pt, every thumbnail blank, or the thumbnail
showing content where we have no ink. Canvas, per band: F1 < 0.90, ink ratio
outside 0.75–1.33 (as `CanvasHostRenderingTests`), a bounding-box edge off by
> 3 pt, or a scroll position that does not reach the band. Informational, not
failures: `stale-thumbnails`, `has-media`, `pdf-template`, `low-res-thumbnail-only` (judged by darkness correlation ≥ 0.6 instead). Each flagged note
gets a first-guess root cause (canvas conversion, stale thumbnail,
unsupported images or PDF template paper, else importer geometry) that the
images confirm or correct.

**Limits.** The oracle sees only the first page (thumbnails show nothing
else) and none of the PDF notes in the sample backup has ink on its first
page, so PDF page geometry beyond page 1 rests on
`testRecognitionOriginsMatchInkOnEveryPage`. Thumbnails of notes with images
or PDF template paper show content the importer drops; those notes'
geometry metrics are not meaningful. `thumbnail` / `thumbnail2x` (binary
plists, newer notes) are not read.

## Package layout

A `.note` is a zip holding one directory named after the note:

| Path | Content |
| --- | --- |
| `<name>/Session.plist` | the note (NSKeyedArchiver, `$top` key `$0`) |
| `<name>/metadata.plist` | title, subject, tags, dates, uuid (NSKeyedArchiver, `$top` key `root`) |
| `<name>/HandwritingIndex/index.plist` | Notability's handwriting recognition (plain binary plist); absent on notes without ink |
| `<name>/Recordings/library.plist` | audio recordings (`recordings` dictionary) |
| `<name>/thumb.png`, `thumb2x` … `thumb12x.png` | first-page thumbnails, 48 px wide × scale. Some are stale (blank paper). |
| `<name>/PDFs/*.pdf`, `NBPDFIndex/` | imported PDFs the ink sits on |
| `<name>/Images/`, `Assets/` | media |

File names inside the zip contain `:` (the note's creation time).

## metadata.plist

`noteName`, `noteSubject` (`unsortedNotesKey` means none), `noteTags`
(string; empty in every sample, treated as comma or newline separated),
`noteCreationDateKey`, `noteModifiedDateKey` (NSDate: seconds since
2001-01-01), `uuidKey` (uppercase UUID string, Notability's stable id),
`notePackagePath`, plus `noteLastChangeDatePerTypeKey`,
`galleryPublishHistoryKey`, `noteHasRecordingKey`, `associatedProductsKey`.
`Session.plist` repeats `name` (as NSData holding UTF-8), `subject`, `tags`
and `creationDate`; they are the fallback.

## Session.plist

Root class `NoteTakingSession`:

- `sessionFormatVersion` (5–9), `NBNoteTakingSessionBundleVersionNumberKey`
  (app version, e.g. `14.2.6`).
- `NBNoteTakingSessionDocumentPaperLayoutModelKey` →
  `documentPaperAttributes` (absent before format 6): `paperIdentifier`
  (`Legacy:13`, or `TemplatePDF:<uuid>:#FFFFFF` for a PDF template),
  `paperSize` (`letter`, or `custom:<width/height>`), `paperOrientation`,
  `paperSizingBehavior` (`lockedWidth:<w>:<device>`, `deviceBasedWidth`,
  `staticWidth`), `lineStyle` (integer, older) and/or `lineStyle2` (string).
- `paperLineStyle`, `paperIndex`: the older integer paper fields at the root.
- `richText` (`FormattedString`): `attributedString` (typed text,
  `stringKey`), `Handwriting Overlay` → `SpatialHash` (the ink, below),
  `reflowState` (`NBReflowStateLocked` with `pageWidthInDocumentCoordsKey`,
  or `NBReflowStateReflowable`), `pdfFiles` (`PDFFile` objects: `pdfFileName`
  under `PDFs/`, `highlights`, always empty in the samples), `pageLayoutArray`
  (one dictionary per page of a note made from a PDF:
  `kPageLayoutDocumentPageNumberKey`, `kPageLayoutPDFFileNameKey`,
  `kPageLayoutPDFFileKey`, `kPageLayoutPDFPageNumberKey`,
  `kPageLayoutPDFIsOriginalPageKey`, `kPageLayoutPageIsBookmarkedKey`; empty
  on paper notes), and `mediaObjects` (`ImageMediaObject`, …).
- `NBNoteTakingSessionIsHighlighterBehindTextKey` (true in every sample).

### Ink: `InkedSpatialHash`

All arrays are little-endian and concatenated over curves in drawing order.

| Key | Encoding | Meaning |
| --- | --- | --- |
| `numcurves` | int | curve count *n* |
| `numpoints` | int | total stored points |
| `numfractionalwidths` | int | total on-curve points (see below) |
| `curvesnumpoints` | int32 × *n* | points per curve, always `3k + 1` (a curve that is not is read as a polyline with one value per point; never seen) |
| `curvespoints` | float32 (x, y) × numpoints | **piecewise cubic Bézier control polygons**: on-curve, control, control, on-curve, … |
| `curveswidth` | float32 × *n* | base width, document units |
| `curvesfractionalwidths` | float32 × numfractionalwidths | width multiplier per **on-curve** point (`k + 1` per curve) |
| `curvesforces` | float32, per on-curve point | force (format ≥ 8; always 1.0 in the samples) |
| `curvesaltitudeangles` | float32, per on-curve point | radians (always π/2 in the samples) |
| `curvesazimuthunitvector` | float32 (x, y), per on-curve point | unit vector (always (1, 0) in the samples) |
| `curvescolors` | 4 bytes × *n* | **RGBA** (`000000ff` black, `006fffff` blue, `ed3624ff` red, highlighter `ffff006b`) |
| `curvesstyles` | uint8 × *n* | **3 pen, 4 highlighter**; nothing else seen |
| `curveUUIDs` | 16 bytes × *n* | per-curve UUID (format ≥ 8) |
| `options` | 8 bytes × *n* | all zero in the samples; unknown |
| `eventTokens` | 4 bytes × *n* | playback sync with recordings (older formats); `ffffffff` when none |
| `dashStyles` | nested binary plist | `{objectPatterns: {"<curve index>": {pattern: 1}}}`: dashed curves |
| `groupsArrays`, `bezierPathsDataDictionary` | | always empty in the samples |

The count relation `numfractionalwidths = Σ (numpoints_i − 1) / 3 + 1` holds
for every curve of every sample, which is what identifies the points as
Bézier control polygons rather than samples. Segments are short (median
chord 1.2 units, 90th percentile 3.9).

Highlighter alpha is stored in the colour (`0x6B` ≈ 0.42); pens are opaque.
Rendered stroke diameter is `curveswidth × fractional width`: rendering
that way matches the total ink darkness of Notability's thumbnails within
2 %. Typical pen widths are 0.933, 1.4 and 1.867 units; highlighters 6 and 28.

### Coordinates and pages

Document units: the page is `W` units wide, where `W` comes from
`lockedWidth:<W>:…`, else `reflowState.pageWidthInDocumentCoordsKey`
(716.8 for iPad notes, 572 for Mac notes, 583.8 / 610 seen). Ink x is offset:
**x = 0 lies 18.8 units in from the left page edge** (measured against the
thumbnails of 49 notes across format versions 5–9, consistent to ±1 unit;
ink spans about −18 … 698 on a 716.8 page). y is not offset. The importer
adds `W × 18.8 / 716.8` to every x.

Notability pages stack vertically without gaps. One page is `W × aspect`
high, where the aspect is `1 / r` for `paperSize = custom:<r>`, else the
height/width of the widest thumbnail (`thumb12x.png` is 576 px wide, so its
aspect is more precise than `thumb.png`'s 48), else 21/16. Thumbnails are
hints: one that cannot be read is skipped, and an aspect outside 1/16…16 (from
a thumbnail or `custom:`) is ignored, as is a document width outside
16…100 000, so a corrupt note cannot produce a page height of 0, of 10¹² or
of infinity. Every "letter" note has 48 × 63
thumbnails (21/16 = 1.3125, not letter's 1.294), and fitting the handwriting
index origins to stroke positions gives a page height of 940.8 = 716.8 ×
21/16 independently.

**PDF pages.** In a note made from a PDF every page is a PDF page
(`pageLayoutArray`, in PDF page order; no blank pages inserted in any sample),
laid out at the document width, and the thumbnails show the PDF's aspect. The
ink of such a note is in the same `InkedSpatialHash`, in the same continuous
coordinates. Its pages repeat every `⌈W × aspect⌉` units, not `W × aspect`:
fitting the handwriting index origins to the ink (26 recognised pages of
PDF notes, up to page 64) gives 538.02 for 716.8 × 0.75 = 537.6 and 429.01 for
572 × 0.75 = 429. Without the rounding, page 39 is 16 units off. Rounding to
the nearest unit fits the same data; 16:9 slides (403.2 → 404) have no
recognised pages in the samples, so that case is unverified. All PDF pages
of one note had the same size in the samples; a PDF with mixed page sizes
would need the PDF's page boxes, which the importer does not read. A PDF note
without a usable thumbnail falls back to 21/16 like paper, rounded up too
(941 on a 716.8 note): a guess either way.

### Paper

| `lineStyle2` | Pattern | Pitch |
| --- | --- | --- |
| `No Lines` | blank | |
| `Dots:<s>` (two fields, older) | dot | `s × 37.6 × W / 716.8` (0.5 → 18.8; measured) |
| `Lines:<s>` | ruled | same rule |
| `Dots:<a>:<b>:<s>` (four fields, newer) | dot | `s` inches on the physical paper: `s × W / 8.5` for letter (0.25 → 21.08, 0.1968505 = 5 mm → 16.6; measured) |
| `Grid:…` | grid | same rules (not seen) |
| anything else | blank | |

Without `lineStyle2`, the integer `lineStyle` / `paperLineStyle` is used:
0 blank, 1 ruled, 9 dot (pitch as `…:0.5`), matching how they co-occur
with `lineStyle2`. The two boolean fields of the newer form are unknown.
Paper colours are not stored per note; the defaults are used.

The imported `paper` (format.md §5.4.1) takes `kind` and `spacing` from this
table and every other parameter from the kind's defaults (white page, default
line colour and width, dot radius 0.9 pt). The reverse-engineered data has no
line colour, line width, margin or page colour, and no Cornell, staff or
isometric styles (`lineStyle2` values for them are not known and import as
blank paper), so nothing richer is mapped; the importer's output is unchanged
by the parametric paper. A note imported before can be restyled in the app
(paper picker, "Apply to all pages").

## HandwritingIndex/index.plist

`version` and `minCompatibleVersion` (7), and `pages`: a dictionary keyed by
1-based page number (as a string) with:

- `text`: recognised handwriting, lines separated by `\n`.
- `characterRects`: per UTF-16 unit of `text`, four little-endian
  **IEEE half floats** (x, y, w, h) — 8 bytes per character, relative to
  `pageContentOrigin`. Whitespace has `(inf, inf, 0, 0)`.
- `pageContentOrigin`: `[x, y]` within the page, in ink coordinates (it is
  the top-left of the page's ink, less about 0.7).
- `returnIndexes` (line breaks), `sha256Hash` (of the page content).

Only pages with recognised ink are listed. The importer merges them into
the single page's `recognition`: texts joined with `\n` in page order,
words grouped between whitespace with the union of their character boxes,
moved by `pageContentOrigin`, the 18.8-unit inset and `(n − 1) × page
height`. `engine` is `notability-<app version>`.

## Mapping

| Notability | InkVault |
| --- | --- |
| `noteName` | `title` |
| folders under `Notability/`, else subject | `notebook` |
| `noteTags` | `tags` |
| `noteCreationDateKey` | `created` (via the delta's `wall`) |
| document width, content extent | one infinite page: `pageSize.width = W`, `height` = lowest ink (at least one Notability page), `breakHeight` = one Notability page (`W × aspect`, usually 21/16; `⌈W × aspect⌉` on PDF pages), all × `612 / W` when scaling |
| `lineStyle2` / `lineStyle` | `paper.kind`, `paper.spacing` |
| curve | one `Stroke`; id derived from the note uuid and curve index |
| style 3 / 4 | `pen` / `marker` (highlighters are written first so they sit behind the ink) |
| colour bytes | `ink.color`; for markers alpha is set to opaque, since the marker tool supplies the translucency (as PencilKit's does; InkRender draws markers at 50 %, where Notability's stored alpha 0x6B shows highlighters at about 42 %) |
| `curveswidth` | `ink.width` |
| Bézier polygon | B-spline control points (below) |
| width × fractional width | `w`, `h` |
| force, altitude, atan2(azimuth vector) | `f`, `al`, `az` (0, π/2, 0 when absent) |
| | `o = 1`, `t = index / 120 s` (no timing is stored) |
| handwriting index | page `recognition` |

**Curves.** Each Bézier segment is sampled (one sample per 3 units of
control-polygon length, 1–8 per segment), attributes interpolated linearly
between its two on-curve points, and the B-spline control points solved
(one tridiagonal system per stroke) so the uniform cubic B-spline passes
through every sample, using the renderer's end rule (the curve starts and
ends exactly on the first and last control point, so no duplicated end
points are needed). The result interpolates Notability's own on-curve
points; between samples it is a C² cubic within a small fraction of a unit
of the Bézier.

## Not imported

| What | Why |
| --- | --- |
| PDF backgrounds (`pdfFiles`, 26 of 130 sample notes) and PDF templates | the format has no page backgrounds yet; the ink is imported in place, so it floats on blank paper. The report counts the PDF pages (`dropped.pdfPages`). |
| Images and other media (`mediaObjects`) | no image support in the format |
| Typed text (`attributedString`) | the format has no typed text (`DESIGN.md` non-goals); counted in the report. In the samples it was only newlines. |
| Audio recordings and playback events | non-goal |
| Dashed strokes | no dash attribute; imported solid and counted |
| Paper colours, PDF-template paper | not stored per note; defaults used |
| Page structure | the note becomes one infinite page; its `breakHeight` makes exports break where Notability's pages did |
| `options`, `groupsArrays`, `bezierPathsDataDictionary`, `eventTokens` | empty or unknown |

**Notes that import with no strokes.** 17 of the 127 imported sample notes
have none, and none of them has any ink to import: their `InkedSpatialHash`
is empty (`numcurves` 0, empty arrays), they have no
`HandwritingIndex/index.plist`, their `PDFFile.highlights` are empty, and
their PDFs carry no ink annotations. 15 are PDFs that were never written on
(the CLI prints `no ink in …` for them) and 2 are blank paper notes. Their
content arrives with PDF backgrounds (Phase 3). `testNotesWithoutCurvesAreInkless`
checks this on a backup.

`deviceBasedWidth` notes without a recorded width (two empty samples) use
716.8, widened to fit any ink beyond it.
