# Undecoded Notability kinds (GA-27): feasibility

Written 2026-10-09 in a cloud session with no access to the maintainer's backup, so
frequencies are the ones the importer docs and `docs/HANDOFF.md` record from earlier
driver surveys; the public fixtures are synthetic and hold one of each kind to test the
counting. Nothing below was measured here.

## What is left out, how often, what it needs

| Kind | Where | Frequency (backup survey) | What decoding needs | Effort |
| --- | --- | --- | --- | --- |
| Dashed strokes | `.note` `dashStyles.objectPatterns`; `.ntb` stroke field 5 (1, 2) | 310 strokes (HANDOFF, full import) | **A format change.** `format.md` has no dash attribute on strokes (nor does PencilKit draw one). A `dash` register on a stroke needs: `format.md` §5.5 (field, merge, validation), `Stroke` model and reader/writer, the three renderers (PNG, SVG, PDF) and the web viewer's port (golden fixtures), the app's `StrokeConversion` and `StrokeLedger` (PencilKit ink cannot be dashed, so the canvas would show it solid and only exports would dash it), and the importers' pattern mapping (pattern 1 and 2 are two dash lengths, unconfirmed). | L (2–4 days, touches the normative format) |
| `.ntb` stroke geometry kind 7 | record type 15, geometry byte 3 | 14 of 632 880 strokes (0.002 %) | A hex dump of one geometry blob (header, node count, first bytes) from the driver; the kind-3 layout is known, kind 7 is probably a different curve encoding (or a shape-tool stroke). Cannot be guessed. | S once a sample exists, M if the encoding is new |
| `.ntb` shape kinds other than line | record type 18, field 4 | 273 shape records in all; the split by kind is not recorded. `.note` has `circle` and `partialshape` for 287 shapes in 9 notes, converted | The payload layout of each kind (which table holds the rectangle corners or the path). The `.note` converters (`NotabilityShapes`) already turn a rectangle or path into curves, so only the FlatBuffer field reader is new. Needs one dump per kind. | M (one kind at a time) |
| `.ntb` stroke segment flags other than 0 and 3 | geometry | never seen | nothing yet | – |
| `.ntb` record types 3, 7, 8, 12, 13 | record type | 1 126, 630, 8, 46, 40 | They are ignored; their meaning is unknown (structural, or text/lasso/image-adjacent). A survey of their field tables would say whether any holds visible content. | M, speculative |
| Highlighter behind a PDF page's text | `markersBehindText` | measured on 1 note | Documented: markers go under text boxes and images, not under a PDF background (layer 0). Making them go under the PDF's own text needs the renderers to split a PDF page into a background and a text layer, which the format cannot express. | L, format change |
| Pages of two heights | notes made from a PDF with paper pages inserted | 4 notes | Documented: one `breakHeight` per note. Needs per-page heights in the page model (`format.md` §5.4.3 has one `pageSize`). | L, format change |

## What this PR changes

- The importer now says *which* kind each unconverted `.ntb` record was
  (`stroke of geometry kind 7`, `shape of kind 2`, …) in the note's warnings, with counts
  (`NotabilityNote.unsupportedKinds`). One run of `sempere import notability --dry-run -v` on the
  backup then yields the split the table above lacks, without quoting any content.
- Nothing is decoded: every candidate either needs a sample from the real backup or a format change.

## Recommendation

1. Run the dry run above and send the kind counts (counts only).
2. Decode kind 7 and the commonest shape kind if the samples are small; each is a half-day.
3. Leave dashes, highlighter-behind-PDF and two-height pages as documented gaps for the first
   release unless the maintainer wants a format change; dashes are the only one a user would notice
   (310 strokes), and a solid line is a faithful reading of the ink.
