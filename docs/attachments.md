# Attachments: typed text, images, audio, PDF pages

Design, 2026-10-05. Status: **proposed**, for review. `docs/format.md` §8
(and the paragraphs marked *new: attachments* in §1–§7) is the normative
part; this document records why, what was rejected, how each exporter,
importer and app feature should use it, and how the work splits into
independent tasks.

## Contents

1. Scope
2. Storage: blobs
3. Integrity and the blob name
4. Collection (GC), history and sync
5. Placed items and their merge
6. Text boxes
7. Images
8. PDF page backgrounds
9. Audio recordings and transcripts
10. Rendering and export (InkRender)
11. Notability import
12. Compatibility and versioning
13. Apple-side notes (app tasks)
14. Implementation tasks
15. Decisions to confirm

## 1. Scope

In scope: typed text boxes on a page, images, PDF pages as page backgrounds
(annotating PDFs, Notability's 26 PDF notes), audio recordings with
on-device transcripts, and the link between ink and audio ("tap a stroke to
hear what was said").

Not in scope: typed-text *documents* (reflowing text with ink anchored to
it), video, arbitrary file attachments, shapes, links, collaboration. The
open item model (§12) lets some of these come later without a format bump.

Constraints carried over from `DESIGN.md` and `CLAUDE.md`: everything at rest
is age-encrypted to the vault recipients and HMAC-bound to the vault secret;
files are write-once; sync tools see only new files; `Sources/` stays pure
Swift on Foundation, swift-crypto and zlib; a user can recover their data
with stock tools.

## 2. Storage: blobs

### Two kinds of data

Attachments mix small, mutable data (where a text box sits, what it says, a
recording's title) with large, immutable bytes (a 3 MB photo, a 40 MB PDF, a
30 MB hour of audio). The first kind belongs in the note log, where it merges
like everything else. The second must not: every snapshot repeats the full
state, so a photo inlined in a revision would be copied into every snapshot
and every restore, and gzip(JSON) of base64 would cost 33 % on top. So large
bytes go into separate encrypted files, *blobs*, that revisions reference by
content hash (`format.md` §8.1.1).

### Layout: one vault-wide `blobs/` directory

```
Notes.inkvault/
  blobs/
    3c7e…(64 hex).age
```

Alternatives considered:

| Layout | For | Against |
| --- | --- | --- |
| **`blobs/<keyed hash>.age`** (chosen) | one copy of a PDF or image however many notes use it (Notability "copies" of a note, the same slides in two notes, re-imports); a re-import or a copy-paste between notes writes no bytes; one directory to list and sync | collection must look at every note (§4); equality of content across notes is visible to the storage (only as "one file") |
| `notes/<id>/att/<hash>.age` | collection is per note; deleting a note's folder takes its blobs | no dedupe across notes; a note directory is no longer only revisions, so `notes/` listing, sync and verify code all change; the same PDF imported into three notes costs three times |
| `blobs/<hash>.<kind>.age` | type visible without decrypting | leaks "this vault has audio"; the type is already in the reference and in the content |
| fan-out `blobs/ab/<hash>.age` | small directories | personal vaults hold thousands of blobs, not millions; WebDAV would need one PROPFIND per bucket; iCloud is fine with flat directories |

A flat `blobs/` keeps sync to one extra listing, keeps `notes/<id>/` exactly
as it is, and makes dedupe free.

### Framing and padding

The plaintext is a 45-byte header (`INKB`, version, content SHA-256, length)
then the content byte for byte, then zero padding (`format.md` §8.1.3). The
content is stored raw, not gzipped: JPEG, PNG, PDF and AAC are already
compressed, and raw bytes make the stock-tool recovery a `tail | head`.

The header carries the content hash so that a reader can check the blob's
name, and a recipient change can check that a blob is complete, from the
first 64 KiB STREAM chunk alone, without reading a 500 MB file. It carries
the length so that padding can follow the content.

Padding: without it a blob's size gives its content's size to the byte (age
adds a fixed header and 16 bytes per 64 KiB), and the size of a known PDF or
photo identifies it as surely as its hash. Padmé (Nikitin et al., PETS 2019)
rounds to a size class with at most 12 % overhead (about 3 % at 1 MB) and
leaves `O(log log n)` bits of size information. It is a *should*: readers
accept any zero padding, so a writer may skip it. Revision files are not
padded (their sizes say little about content and they are small).

### Large files

- **Streaming.** age's STREAM payload authenticates 64 KiB chunks, so
  encryption and decryption run in constant memory. `Sources/Age` today
  offers one-shot `Data` APIs; task B1 adds file-to-file and chunk-iterator
  APIs. Blobs over 16 MiB must be streamed (`format.md` §8.1.4).
- **Random access.** PDF parsing needs it. Readers decrypt the blob into a
  private temporary file (deleted immediately after use; on iOS inside the
  app container, which Data Protection encrypts) and read that. Audio playback
  on iOS reads from the same kind of temporary file (AVPlayer needs a URL).
  Plaintext never goes to a shared or synced location.
- **Size cap.** 1 GiB per blob (`format.md` §8.4): about 35 hours of 64 kbit/s
  AAC, any realistic PDF. WebDAV sync gets a separate limit for blobs
  (currently 256 MiB for everything) and must stream GET to a file and PUT
  from a file instead of holding `Data`.
- **Write order.** Blob first, durable, then the delta that references it
  (`format.md` §8.1.4). A crash in between leaves an unreferenced blob, which
  collection removes later; never a reference to nothing.

## 3. Integrity and the blob name

Requirement: attachment bytes are bound to the vault secret like revision
bodies, so storage write access does not let anyone plant content.

Revision bodies carry an HMAC tag inside the encrypted plaintext. Doing the
same for blobs has one bad consequence: when a recipient is removed, the
vault secret rotates and every tag must be recomputed, and a tag inside an
age payload can only be changed by re-encrypting the whole payload (keeping
the file key and nonce and re-encrypting one chunk would reuse a
ChaCha20-Poly1305 nonce). Removing a lost iPad would re-encrypt gigabytes.

Chosen instead: **the name is the tag.** `blobName = HMAC-SHA256(vaultSecret,
"inkvault/1" ‖ 0 ‖ "blob" ‖ 0 ‖ sha256(content))`. A blob is authentic when
its content hashes to the value in its header and the name derived from that
hash under the vault secret is its file name; only a holder of the secret can
produce that name. Read through a reference, the hash must also equal the
`sha256` in the referencing revision, which is itself HMAC-tagged: that is a
stronger binding than any tag (exactly this content, for exactly this item).

The same HMAC keys the name, which answers the second requirement: names must
not leak plaintext content hashes. With plain SHA-256 names anyone with read
access to the storage (the provider, a backup service, a thief with the
iCloud password) could confirm that the vault contains a given file by
hashing it. The keyed name stops that, and padding (§2) stops the same
confirmation by size. What remains visible: the number of blobs, their size
class, their times, and that one content is used once (dedupe).

Domain separation: body tags hash `"inkvault/1" ‖ 0 ‖ noteId ‖ …` and a
note id is never `blob`, so the two message spaces cannot collide.

Why not bind the note id into the name? Content-addressing across notes is
the point of the layout; the note binding comes from the reference.

### Recipient changes

On a removal the vault secret rotates, so names change: the rewrap renames
each blob (writes the new name, deletes the old), with lookups falling back
to the previous secret's name while the journal exists (`format.md` §8.1.5).

The rewrap *should* keep each blob's file key and rewrite only the age header
(new stanzas, new header MAC, nonce and payload copied). Cost: one header
write and one file copy per blob instead of decrypting and re-encrypting it.
Risk: a removed recipient who kept the *old header* of a blob can still
unwrap its file key and read the payload. But to have the old header they
had read access to the old file, payload included, and their identity could
decrypt it then; nothing becomes readable that was not already. New blobs get
new file keys. A user who wants old blobs re-keyed (for example if a key
leaked but storage did not) can force full re-encryption (`may` in §8.1.5;
task B2 exposes it as an option). This needs a new Age API (B1): unwrap the
file key with an identity, re-wrap it to new recipients, emit a header.

Note: a recipient change by an *older* build (one that predates blobs)
rewraps `notes/` only and deletes the journal, leaving blobs encrypted to
the old set and named under the old secret. That is why writers add
`features: ["attachments"]` to `vault.json` (`format.md` §2) and why every
device must run a blob-aware build before the first attachment is written.
Builds from before this change ignore `features` (pre-1.0, no migration);
repair is possible regardless, since a blob's header names its content hash:
decrypt, re-derive the name, rename (task B2's `blobs repair`).

## 4. Collection (GC), history and sync

### When a blob may be deleted

Compaction deletes revisions only when coverage proves nothing is lost. The
blob rule mirrors it (`format.md` §8.1.6): a blob goes only when the whole
vault was read without error, no revision anywhere (snapshot or delta, any
note, deleted notes too) references its hash, and the collecting device saw
it unreferenced for at least the retention window.

- *Any revision, not just the current state.* A restore point (`format.md`
  §5.7) may show an image that was deleted since. As long as the revision
  that shows it survives, so does the blob; once compaction removes every
  revision referencing it, the blob can go too. History and attachments
  never disagree.
- *Whole vault readable.* An unreadable revision might be the only reference
  (as an unreadable snapshot never counts as coverage).
- *Structural reference test.* Any JSON object with a `sha256` key counts,
  so an older collector keeps blobs referenced by item kinds it does not
  know.
- *Grace window.* Reuse makes collection racy: device B, offline, finds blob
  X on disk and writes a delta using it, while A collects X because nothing
  referenced it. The window (device-local "first seen unreferenced" times)
  means B must stay unsynced for 30 days for the race to bite. It cannot be
  closed without coordination, which the format does not have. Readers report
  the dangling reference and draw a placeholder; a device that still has the
  content (the importer, the app that recorded it) writes it again.

Collection is explicit (`inkvault blobs gc`, a button in the app's
maintenance screen), never a side effect of opening, syncing or compacting.

### WebDAV

`blobs/` becomes a synced collection with the same write-once table as
revisions (`docs/io.md`): upload with `If-None-Match: *`, download to a
temporary file and `link(2)` into place, never overwrite. A blob dropped on
one side is deleted on the other only if `format.md` §8.1.6 rules 1–3 hold
there (the side that dropped it applied rule 4); otherwise it is copied back.
Names must be 64 lowercase hex plus `.age`; a downloaded blob must start with
the age header. Blobs are streamed both ways with their own size limit.

A recipient removal renames every blob, which sync sees as "all blobs
dropped, all new blobs added". As for rewritten revisions, the documented
procedure after a recipient change is a fresh collection.

### iCloud Drive

Unchanged rules (the app downloads before reading, coordinates writes), with
one difference: blobs are not downloaded when the vault opens. The app
requests the blobs a note references when the note is opened or exported
(`startDownloadingUbiquitousItem`), shows a per-item spinner, and draws a
placeholder until the file arrives. Evicting blobs is harmless since they
never change. The vault-open scan skips `blobs/` except to list it.

## 5. Placed items and their merge

Text boxes, images and PDF pages are one concept, a *placed item* (`format.md`
§8.2): an id, a kind, a layer, a frame and rotation in page coordinates, an
order key, and kind-specific fields. One shape means one set of ops, one
merge, one selection and move UI, one hit test, one placeholder rule.

### Mutable registers vs immutable items

Strokes are immutable: editing one is remove + add with `parent`. Doing the
same for items was considered and rejected:

| | LWW registers per field (chosen) | Immutable, replace with remove + add |
| --- | --- | --- |
| concurrent moves of one image | last move wins, one image | both survive: two copies of the image |
| move on A, crop on B | both apply (different fields) | two copies |
| concurrent text edits | last edit wins; the other is in history | both versions kept as two boxes |
| ops per drag | one `setItem` | one remove + one add, new id each time |
| item identity | stable for the item's life (good for `rec`, search hits, selection) | changes on every edit |

Duplicated photos after an offline move are a visible, confusing failure;
a lost concurrent text edit is rare for a one-person app and recoverable from
history. Registers follow the existing LWW patterns exactly (`setPageOrder`
with `orderClock`, `setMeta` with `clocks`), so the reducer already has the
machinery. The add/remove side is the stroke rule: set union, removes win,
covered-add removal (a snapshot covering the add but not holding the item has
seen it removed).

Tombstones for items and recordings are permanent, like pages, not pruned
like strokes: a late `setItem` must be distinguishable from one whose
`addItem` has not arrived (orphan, re-applied later, `format.md` §5.3) or the
setter's delta would stay uncovered forever. Items are few (tens per note),
so the cost is nil.

### Layers and z-order

Ink is always on top of every item, and items sit in two layers
(`format.md` §8.2.3): `background` (PDF pages; drawn with a paper-coloured
fill that hides the ruling under them) and `content` (images, text). Within
a layer items order by an order key `z`, like pages.

Why not interleave items and strokes freely? PencilKit draws the whole
drawing in one view; an image between two strokes would need the drawing
split into two canvases. Annotating images and PDFs (writing on top) is the
use case; putting a photo over ink is not. Notability also keeps ink above
media. A future `overlay` layer above ink would be an unknown layer value
(`content`) to old readers, which is acceptable.

Why does a background hide the ruling? Ruled paper over a PDF slide is never
what anyone wants, and many PDFs do not paint their own white page (the
ruling would show through). Images in the content layer do not knock out the
ruling: a transparent PNG on ruled paper shows the ruling, as on paper.

## 6. Text boxes

### Plain or rich

Options considered: plain text with one style per box; minimal rich text
(runs with bold, italic, underline, strikethrough, colour, size); full rich
text (fonts, lists, paragraph styles, links).

Chosen: **minimal rich text**, a box-level family/size/colour/alignment plus
runs (`format.md` §8.2.4). Bold, a colour and a bigger size are what
handwriting apps' text boxes get used for (headings, labels); lists can be
typed as `•` lines. The whole text is one LWW register, so runs add no merge
complexity. The renderer needs only three generic families with regular,
bold and italic faces.

### Fonts and identical line breaks

A text box's lines must break in the same places on the iPad, in an exported
PDF on Linux, and in a PNG: otherwise a label that fits on screen overflows
in the export. That requires the same font metrics and the same line-breaking
rules everywhere. So:

- The format fixes the layout rules (`format.md` §8.5.3): greedy breaking at
  white space and hyphens, no kerning, fixed line height and baseline.
- InkRender bundles the fonts and implements the layout once
  (`InkRender.TextLayout`, pure Swift). The app uses the same bundled fonts
  and the same `TextLayout` to draw committed text (CoreText draws the
  glyphs at the computed positions); only the live editor (a `UITextView`)
  uses TextKit, and its small differences last only while editing.
- Recommended fonts: **DejaVu Sans, DejaVu Serif, DejaVu Sans Mono**,
  regular and bold (italic synthesised by a 12° slant), as TrueType (`glyf`)
  files. License: Bitstream Vera / public domain, redistributable with
  GPL code. Coverage: Latin, Greek, Cyrillic, maths symbols and arrows, which
  covers lecture notes. About 4 MB for six files. Not covered: CJK, Arabic,
  Indic scripts; such characters render as missing-glyph boxes in exports (the
  app can still show them while editing, from system fallback). A later
  change can add a Noto subset.
- Alternatives: the PDF standard 14 fonts (no embedding) cover only Latin-1,
  have no outlines for PNG export, and differ from the app's system font;
  system fonts (SF Pro) cannot be embedded on Linux or redistributed.

### Search and recognition

Typed text is exact, so it is searchable as is (CLI `search`, the app's
search) and highlighted with the line boxes from `TextLayout`. It is never
copied into `recognition`, which stays derived from ink. PencilKit's Scribble
works in the app's text editor for free (handwriting converted to typed
text as you write in a text box).

## 7. Images

- **Formats.** JPEG and PNG only, because those are what PDF and SVG can
  carry and what a pure-Swift decoder can reasonably handle. HEIC (the iPad
  camera's default), WebP, GIF, TIFF are converted when added (the app via
  ImageIO: JPEG quality 0.9 for photos, PNG when the source has alpha or is
  a screenshot). Linux importers that meet another format report it dropped.
- **Metadata stripping.** Exporters pass JPEG bytes straight into PDFs
  (DCTDecode), so EXIF in the blob would end up in a shared PDF, location
  included. Writers drop APPn/COM segments and ancillary PNG chunks
  (`format.md` §8.2.5); this is lossless (segment removal, no re-encode).
- **Orientation** is a field (`orientation`, EXIF 1–8), applied by the
  renderer through the placement transform, so JPEGs are never re-encoded to
  rotate them.
- **Crop** is a register in oriented pixel coordinates; the frame is where
  the crop lands. Rotation is free-angle.
- **Scans.** The document camera produces images; each scanned page can be an
  image item filling a page, or the scan can be saved as a PDF and placed as
  `pdfPage` items. Recommendation: PDF (one blob, one page per scan page,
  `background` layer).

## 8. PDF page backgrounds

### Item and geometry

A `pdfPage` item is a reference to a PDF blob, a page index, a crop on the
page's *effective* box (CropBox ∩ MediaBox turned by `/Rotate`), and a frame
(`format.md` §8.2.6, §8.5.1). It is an ordinary item, so it can be on a
finite page, in a band of an infinite page, or (as `content`) a figure.

### How PDF pages become note pages

The format does not fix this; two layouts, both supported by the same item:

- **Import a PDF (app, CLI `import pdf`).** One note, one finite note page per
  PDF page, each with one `pdfPage` item in the `background` layer whose
  frame fills the page. The note's `pageSize` is the first page's effective
  size, so an exported PDF has the original's page size. Pages of another
  size are fitted (uniform scale, centred) into the note's page size, since
  `pageSize` is per note (a per-page size is a possible later extension).
  Paper is `blank`. A PDF with more than 2 000 pages is refused.
- **Notability import.** One infinite page (as today) with one `pdfPage` per
  PDF page at the band where Notability placed it (§11).
- **Insert pages from a PDF** into an existing note: new pages after the
  current one, same rules as import.

An infinite page grows beyond a background's frame like any other page; a
background crossing a `breakHeight` is cut across export pages like a
stroke.

### Encryption, forms, annotations

PDFs with `/Encrypt` are refused by Linux importers and decrypted by the app
before storing (PDFKit: unlock, then write without a password; owner-password
"restricted" PDFs unlock with the empty user password). Form fields and other
annotations are not drawn; the app may flatten them before storing (PDFKit
can draw annotation appearances into a new page).

## 9. Audio recordings and transcripts

### Recording item

A recording belongs to the note (`format.md` §8.3.1), not to a page:
Notability shows recordings per note, a recording usually spans many pages,
and nothing is drawn for it.

### Codec

| | AAC-LC in MP4 (`.m4a`) (chosen) | Opus (Ogg or CAF) |
| --- | --- | --- |
| iPad encoder | hardware, `AVAudioRecorder` default | software; AudioToolbox has it, in CAF |
| playback | AVFoundation, every OS, every player | AVFoundation (CAF), browsers (Ogg); not Preview/QuickTime for Ogg |
| speech at 64 kbit/s mono | transparent | transparent at 24–32 kbit/s |
| size per hour | ~29 MB | ~11–14 MB |
| stock tools | `ffmpeg`, any player | `ffmpeg`, `opusdec` |
| Notability recordings | AAC (to confirm, §11) | |

AAC-LC, mono, 48 kHz (the iPad microphone's native rate, no resampling),
64 kbit/s. Opus would halve storage, but the savings are small next to the
compatibility cost (stock players, PDF attachment viewers, Notability import
passthrough). Readers must play `audio/mp4`; other audio types are allowed so
an importer never has to transcode.

### Transcripts

A transcript is derived data (like `recognition`), replaced as a whole, but
much larger: an hour of speech is about 60 KB of text and 0.5 MB of JSON with
word timings. Inline in the recording it would be copied into every snapshot,
so it is a blob (`format.md` §8.3.2) and the recording's `transcript`
register holds the reference. The transcript names its recording id, so a
transcript blob cannot be attached to another recording. Content is plain
JSON so that `age -d … | tail -c +46 | head -c L | jq .` reads it.

Segments carry start/end times, text and optional confidence; words are
optional (SpeechTranscriber gives time ranges per run; SFSpeechRecognizer per
segment). `engine` records what produced it, as recognition does.

### Ink and audio sync

`rec: {id, at}` on a stroke or item (`format.md` §5.6, §8.3.3) is set when the
stroke is added and never changes, which fits immutable strokes: no extra
op, no per-recording event list that would grow with every stroke. Pieces
sliced from a stroke copy it. Uses:

- *Tap a stroke to seek*: play from `rec.at` (minus a lead-in of about 2 s,
  a UI choice).
- *Playback highlights*: strokes with `rec.at` ≤ position are drawn normally,
  later ones faded (Notability's behaviour).
- *Tap a transcript word*: seek to its `start`; strokes whose `at` falls in
  the word's sentence can be highlighted.
- *Tap a recognised word*: find the strokes under its box, take the smallest
  `at`.

The app takes `at` from `PKStroke.path.creationDate` minus the recording's
start date (both wall clock; PencilKit records stroke creation dates).

## 10. Rendering and export (InkRender)

### Inputs

Renderers stay pure: they get the note state plus an optional
`BlobSource` (how to get a blob's verified bytes, or a temporary file for
large ones) and an optional `PDFPageRasterizer` (a hook the app implements
with PDFKit). Without a blob source every blob-backed item is a placeholder
(`format.md` §8.5.2); text renders regardless. Every exporter returns a list
of placeholders and warnings, which the CLI prints.

### Per item type and exporter

| | PDF | SVG | PNG |
| --- | --- | --- | --- |
| page order | paper, ruling, background items (with paper fill), content items, strokes (`format.md` §8.2.3) | same | same |
| image, JPEG | Image XObject, **DCTDecode passthrough** of the stored bytes; width, height and components from the SOF marker; orientation, crop, frame and rotation as one `cm` matrix; clipped to the frame | `<image href="data:image/jpeg;base64,…">` with the same matrix in `transform` and a `clipPath`; `--assets DIR` writes files and links them instead | decoded (baseline and progressive JPEG decoder), resampled (bilinear up, area average down) through the inverse placement transform |
| image, PNG | decoded, re-encoded FlateDecode 8-bit RGB or Gray, alpha as `/SMask`; 16-bit reduced to 8; palette expanded | passthrough data URI | decoded |
| PDF page | **Form XObject** imported from the source PDF (below); one XObject per (blob, page) per export, shared resources copied once | placeholder, or a PNG from `PDFPageRasterizer` when given | placeholder, or rasterizer output |
| text | embedded TrueType (Type0 / CIDFontType2, Identity-H, `FontFile2`, `ToUnicode` so text is searchable and copyable), positioned per `TextLayout` | `<text>` per line with `<tspan>` runs at `TextLayout` positions, `font-family="DejaVu Sans, sans-serif"`, `xml:space="preserve"` | glyph outlines from the TrueType `glyf` table, filled with the existing scanline rasterizer |
| recording | not on pages; see below | omitted | omitted |
| unknown kind, missing blob | placeholder | placeholder | placeholder |

Matrices: the content stream starts with `1 0 0 -1 0 H cm` (y down). An image
XObject paints the unit square with y up; a form paints its BBox in PDF user
space. The exporter composes, per item: source → effective/oriented
coordinates (`format.md` §8.5.1 tables) → crop to frame → rotation about the
frame centre, and emits it as one `cm` after `q`, with the frame (rotated)
as clip path (`W n`).

### Minimal PDF reader (for Form XObjects and page boxes)

A new Linux-portable target `InkPDF` (Foundation + CZlib), used by InkRender
(export) and InkImport (page boxes, page count). Subset:

- File structure: header, `startxref` from the last 1 KiB, classic xref
  tables and trailers, xref streams (`/Type /XRef`, `/W`, `/Index`, Flate
  with PNG predictors 10–15), hybrid files (`/XRefStm`), incremental updates
  (`/Prev` chain, newest wins), object streams (`/Type /ObjStm`). If the xref
  is broken, rebuild it by scanning for `n g obj` (real-world PDFs often need
  this).
- Lexer: all object types (null, booleans, integers, reals, literal strings
  with escapes and balanced parentheses, hex strings, names with `#xx`,
  arrays, dictionaries, indirect references, streams with direct or
  indirect `/Length`, `/Length` wrong → scan for `endstream`).
- Page tree: `/Pages` → `/Kids` with inherited `/Resources`, `/MediaBox`,
  `/CropBox`, `/Rotate`; cycle detection, depth ≤ 64.
- Filters, decoding only where needed: FlateDecode (with predictors) for
  xref and object streams and for content streams; content streams in other
  filters (LZW, ASCII85, ASCIIHex, RunLength) are decoded too (all short); a
  content stream with a filter not in this list fails the item (placeholder
  plus warning, or the app's rasterizer). Every other stream (fonts, images
  in DCT, JPX, JBIG2, CCITT) is copied with its filter untouched, never
  decoded.
- Copying a page as a form: the page's content streams decoded and
  concatenated (separated by a newline), re-compressed with Flate;
  `/Resources` deep-copied with every reachable indirect object renumbered
  into the output (one copy per source object per export); `/BBox` = the
  visible box; the page's `/Group` (transparency group) carried to the form.
  Not copied: `/Annots`, `/Parent`, `/StructParents`, `/Metadata`,
  `/PieceInfo`, `/Thumb`, `/B`.
- Refused: `/Encrypt` present. Limits: 10⁶ objects, 256 MiB per decoded
  stream, nesting depth 64, each enforced with an error, never a crash
  (fuzzed in tests).
- Output: `PDFWriter` switches to `%PDF-1.7` when it embeds forms (copied
  objects may use 1.5+ features such as JPX).

### Text, fonts and the PDF writer

v1 embeds each used font file whole (about 700 KB each); subsetting
(rewriting `glyf`/`loca`/`cmap` with only used glyphs) is a separate
optimisation task. Glyph ids come from `cmap` (formats 4 and 12); advances
from `hmtx`. Bold and italic: the bold file; italic via `Tm` shear (12°).

### Audio in exports

Pages never show recordings. Options for the PDF:

- default: nothing; the export report says "2 recordings not exported";
- `--recordings list`: an appended page listing each recording's title,
  date, duration and its transcript text (when there is one);
- `--recordings attach`: the audio files as PDF embedded files
  (`/Names /EmbeddedFiles`, PDF 1.4) plus the list page. Preview, Acrobat and
  most viewers let the user save them.

SVG and PNG exports omit recordings. A separate `inkvault export --format
media` writes the note's original blobs (images, PDFs, audio, transcripts) as
files, named `<title>-<n>.<ext>`.

### Raster limits

Images over 100 megapixels are drawn as placeholders (`format.md` §8.4).
Decoders stop at the image's declared size and at truncated input; JPEG
decoding uses DCT scaling (1/2, 1/4, 1/8) when the output needs fewer pixels,
so a 12 MP photo in a small frame never decodes at full size.

## 11. Notability import

From `docs/import-notability.md` (what is known) and what the importer
drops today (`Dropped`). Every mapping below keeps the existing geometry
(document units × `612 / W`, the 18.8-unit x inset, one infinite page with
`breakHeight`).

### PDF backgrounds (26 of 130 sample notes)

- `richText.pdfFiles` → one blob per `PDFs/<pdfFileName>` (type
  `application/pdf`), deduplicated by content.
- `richText.pageLayoutArray` → one `pdfPage` item per entry, in the
  `background` layer: `pageIndex = kPageLayoutPDFPageNumberKey − 1` (to
  confirm whether it is 0- or 1-based), blob from `kPageLayoutPDFFileNameKey`,
  frame `[0, y, 612, 612 · H'/W']` at
  `y = (kPageLayoutDocumentPageNumberKey − 1) · stride`, where `stride` is the
  page height the importer already computes (`⌈W × aspect⌉ × 612 / W`), and
  `W' × H'` the effective page size read with `InkPDF` (it replaces the
  thumbnail-derived aspect when available, which fixes the mixed-size case).
  `z` follows the page order.
- Paper under PDF pages: the note keeps its paper; the backgrounds hide its
  ruling (`format.md` §8.2.3).
- `TemplatePDF:<uuid>` paper: a PDF used as paper on every page. Map to one
  `pdfPage` per band, all referencing the template's blob (dedupe makes it
  free), once the template's location in the package is known.
- `PDFFile.highlights` were always empty; if found non-empty, they are
  highlights on the PDF (map to marker strokes).
- Acceptance: the 15 ink-less PDF notes import with their pages; the eval
  report's `pdf-template` flags disappear; the oracle compares against the
  thumbnail with the PDF drawn (export with pdfium in the eval scripts).

### Images (4 sample notes)

- `richText.mediaObjects` entries of class `ImageMediaObject` → `image`
  items in the `content` layer. Bytes from `Images/` or `Assets/`; JPEG and
  PNG are stored (metadata stripped); other formats are reported dropped
  (Linux cannot convert; the app's import path can).
- Frame, rotation, crop: from the media object's fields (unknown, below);
  position in the same document coordinates as ink, then scaled.

### Typed text

- `richText.attributedString` is Notability's flowing typed text (the samples
  hold only newlines). Map non-blank text to one `text` item per paragraph
  block at the top of the page, frame width = page width minus Notability's
  text margins (unknown), runs from the attributed string's attributes:
  `NSFont` → family (`Helvetica*`/`SF*`/`Avenir*` → `sans`, `Times*`/
  `Georgia*` → `serif`, `Courier*`/`Menlo*` → `mono`) plus bold/italic from
  the font name, point size × `612 / W`; `NSColor` → `color`; underline and
  strikethrough attributes.
- Text boxes (if Notability stores them as media objects, not in the
  attributed string): one `text` item each.
- Notability reflows ink with typed text (`NBReflowStateReflowable`); the
  import pins text and ink where they were laid out at import time.

### Recordings

- `Recordings/library.plist` (`recordings` dictionary) → one recording per
  entry: blob from the audio file (passthrough: AAC in MP4 or CAF stored as
  is with its media type; `audio/x-caf` is playable by AVFoundation), title,
  start date, duration.
- `eventTokens` (4 bytes per curve, `ffffffff` when none, older formats):
  presumed to map a curve to a playback event; map to the stroke's `rec`
  once decoded. Newer formats (8–9) must store sync elsewhere.
- Notability's own transcripts, if any (newer versions transcribe), map to
  transcript blobs with `engine: notability-<version>`.

### Unknowns to investigate (with the user's backup, never committing it)

1. `ImageMediaObject` (and other `mediaObjects` classes): field names for
   frame, rotation, crop, z-order, file reference; are they in document
   units with the 18.8 inset?
2. Text: where text boxes live (`mediaObjects` class?) vs
   `attributedString`; Notability's text margins and default font.
3. `kPageLayoutPDFPageNumberKey`: 0- or 1-based; meaning of
   `kPageLayoutPDFIsOriginalPageKey` (inserted blank pages?).
4. Notes mixing PDF pages of different sizes: is the stride per page or
   per note?
5. Template PDFs (`TemplatePDF:<uuid>`): where the PDF is stored.
6. `Recordings/library.plist` layout, audio container and codec, start
   times, durations; multiple recordings per note.
7. `eventTokens` encoding and the audio-ink sync of formats 8–9.
8. Whether any PDF in the backup is encrypted, and whether any has
   annotations Notability drew (would need flattening).
9. `NBPDFIndex/`: Notability's PDF text index (could seed search of PDF
   text; out of scope here).

## 12. Compatibility and versioning

`format.md` §7 says readers reject a revision holding an unknown op (fail
closed). That stays right for ops: an op type carries merge semantics, and a
reader that dropped it and then wrote a snapshot claiming to include the
delta would lose the op for every device forever.

Item kinds are different. Every item merges the same way whatever its kind
(set of ids, LWW registers), and a placeholder in its frame is a faithful
degraded rendering. So inside item and recording ops the format is open
(`format.md` §7): unknown kinds and fields are kept, merged generically and
re-emitted unchanged in snapshots; unknown setItem fields are registers.
This means a later build can add, say, `shape` or `link` items without
making every note that uses them unreadable on an older iPad. Costs:

- the core model must keep the raw JSON of unknown fields
  (`[String: JSONValue]` beside the typed fields) and re-encode it verbatim;
- collection must find blob references structurally (`format.md` §8.1.1);
- placeholders must exist in every renderer and in the app.

Strokes and pages stay closed (their unknown fields are dropped by today's
readers); `rec` on strokes is new and is lost if an older build rewrites
a stroke into a snapshot. Pre-1.0 this is acceptable: all devices update
before the first recording.

Versioning: `format` stays `inkvault/1` and the body version byte `0x01`
(pre-1.0, `format.md` §7). Today's builds reject revisions with the new ops
(fail closed, reported) and ignore `blobs/` (unknown directory): they cannot
show notes with attachments but cannot damage them, except through a
recipient change (§3 above). New: `vault.json` `features`, the general
mechanism for "older writers must stay read-only", starting with
`attachments`.

## 13. Apple-side notes (app tasks)

Guidance for the app tasks, not normative. Deployment target iPadOS 26; the
user's iPad is a 2020 iPad Pro (A12Z) on 26.7.1 and cannot run 27, so every
API below must be checked on 26 and, where marked, on that device.

### Writing attachments

All vault writes go through `NoteWriter` (CLAUDE.md). It gains
`addBlob(from: URL, type:) async throws -> BlobRef` (streams through
`Vault.writeBlob`, inside the same coordinated write as the delta in iCloud
Drive), used before the delta that references the blob. Picked files and
recordings are copied into the app container first (security-scoped URLs
expire).

### Audio recording

- `AVAudioRecorder` with `AVFormatIDKey: kAudioFormatMPEG4AAC`,
  `AVSampleRateKey: 48000`, `AVNumberOfChannelsKey: 1`,
  `AVEncoderBitRateKey: 64000`, writing an `.m4a` in the app's temporary
  directory; on stop, `NoteWriter.addBlob` then `addRecording`. Simple and
  robust; transcription runs after the recording ends.
- `AVAudioEngine` (input node tap → `AVAudioFile` with the same AAC
  settings, and the same buffers fed to `SpeechAnalyzer`) is the route to a
  live transcript; more moving parts (format conversion, interruptions). Do
  it second.
- `AVAudioSession`: `.playAndRecord`, mode `.default` (`.spokenAudio` for
  playback), options `.allowBluetoothHFP`/`.defaultToSpeaker`; handle
  interruptions (calls, Siri) and route changes by pausing and appending.
  `UIBackgroundModes: audio` to keep recording with the screen locked or the
  app in the background; microphone usage string in `Info.plist`.
- Long recordings: keep the file on disk, never in memory; a 3-hour lecture
  is about 86 MB. If the app is killed mid-recording, the `.m4a` is not
  finalised; record in segments (for example a new file every 10 minutes,
  stitched as several recordings or concatenated with `AVMutableComposition`
  on stop) so that a crash loses at most one segment.
- `rec.at` for strokes: `PKStroke.path.creationDate − recordingStart`.

### Transcription (on device only)

- Preferred on iPadOS 26: `SpeechAnalyzer` with `SpeechTranscriber`
  (Speech framework, new in 26): file input
  (`analyzeSequence(from: AVAudioFile)`), long-form, word-level time ranges
  (`attributeOptions: [.audioTimeRange]`) and confidence
  (`.transcriptionConfidence`). Model assets come from `AssetInventory`
  (`assetInstallationRequest(supporting:)`); check
  `SpeechTranscriber.supportedLocales` / `installedLocales` and
  `isAvailable` at run time. Device support on the A12Z is **unverified**:
  test on the user's iPad before building UI around it.
- Fallback 1: `DictationTranscriber` (same `SpeechAnalyzer` API, the
  dictation model, broader device support, less accurate for long-form).
- Fallback 2: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
  (only if `supportsOnDeviceRecognition` for the locale) and an
  `SFSpeechURLRecognitionRequest`; segment timestamps and confidence from
  `SFTranscriptionSegment`. Never server recognition (no network, `DESIGN.md`).
- Opt-in per recording or per vault; show progress; write the transcript
  blob, then `setRecording(transcript:)`. `engine` e.g.
  `apple-speechtranscriber-26.7`, `apple-sfspeech-26.7`.
- Permissions: `NSSpeechRecognitionUsageDescription` (needed for
  `SFSpeechRecognizer`; check whether `SpeechTranscriber` needs it).

### Images

- `PhotosPicker` (`PhotosUI`) → `loadTransferable(type: Data.self)` (often
  HEIC) → ImageIO (`CGImageSource`, `CGImageDestination`) to JPEG q 0.9 or
  PNG, metadata dropped, orientation read from the source properties into
  the item. Drag and drop and paste (`UIPasteboard`) take the same path.
- Camera: `UIImagePickerController(.camera)` wrapped in SwiftUI; document
  scanning: VisionKit `VNDocumentCameraViewController` → a PDF
  (`PDFDocument` from the scan images) → `pdfPage` items.
- Display: decode with `CGImageSourceCreateThumbnailAtIndex` at the needed
  pixel size (never full-size for a small frame), cache per zoom level.

### PDF import and display

- `.fileImporter(allowedContentTypes: [.pdf])` → copy into the container →
  `PDFDocument`; if `isEncrypted`, try `unlock(withPassword: "")`, else ask;
  write an unencrypted copy with `write(to:withOptions:)` without password
  options (verify the output has no `/Encrypt`) and store that; otherwise
  store the original bytes unchanged (dedupe across devices relies on it).
- Page geometry: `PDFPage.bounds(for: .cropBox)` and `rotation` give the
  effective size; must agree with `InkPDF` (test both on fixtures).
- Display under `PKCanvasView`: a background view between `PaperView` and
  the canvas, drawing each visible `pdfPage` item with
  `CGContext.drawPDFPage` in a `CATiledLayer` (sharp at 4× zoom without
  holding full-resolution bitmaps); memory bounded by the tile cache.
- `PDFPageRasterizer` for the app's SVG/PNG export, implemented with
  `CGPDFPage` drawing.

### Text editing on the canvas

- A text tool: a `PKToolPickerCustomItem` in the system tool picker
  (iPadOS 18+; build it alongside `EraserPreference`'s items) or a separate
  toolbar control. Tap to create a box; a `UITextView`
  overlay at the frame (converted through the canvas zoom and offset),
  fonts registered from the bundled files with
  `CTFontManagerRegisterFontsForURL`. While editing, the canvas's drawing
  gesture is disabled; Scribble works inside the text view.
- On end of editing: `addItem` (new) or `setItem(text)`; empty new box → no
  op. Debounce like strokes (one delta per pause).
- Committed text drawn with `InkRender.TextLayout` positions and CoreText
  glyph drawing, so it matches exports.
- Selection, move, resize, rotate, delete for all items: a custom overlay
  (PencilKit's lasso selects strokes only). One `setItem(frame)` per
  gesture end, not per frame.

## 14. Implementation tasks

Each task is one branch, one PR, CI green, and updates the docs it touches
(`docs/io.md`, `docs/cli.md`, `docs/import-notability.md`, `docs/plan.md`).
Task **A0** is small and goes first: it defines the model types every other
task compiles against. After A0 merges, everything else can run in
parallel; the dependency notes say what to stub meanwhile.

API sketch (A0 and B2 own these names; others code against them):

```swift
// InkVault (A0)
public enum JSONValue: Hashable, Sendable, Codable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }
public struct Rect: Hashable, Sendable, Codable { var x, y, w, h: Double }                         // [x, y, w, h]
public struct BlobRef: Hashable, Sendable, Codable { var sha256: String; var size: Int64; var type: String; var extra: [String: JSONValue] }
public struct RecordingLink: Hashable, Sendable, Codable { var id: UUID; var at: Double }        // "rec"
public struct TextRun: Hashable, Sendable, Codable { var t: String; var b, i, u, s: Bool; var color: Color?; var size: Double?; var extra: [String: JSONValue] }
public struct TextContent: Hashable, Sendable, Codable { var font: String; var size: Double; var color: Color; var align: String; var runs: [TextRun]; var extra: [String: JSONValue] }
public struct ItemKind: RawRepresentable, Hashable, Sendable, Codable { static let text, image, pdfPage }   // open set
public enum ItemLayer: String, Hashable, Sendable, Codable { case background, content }        // unknown → content
public struct Item: Hashable, Sendable, Codable, Identifiable {
    var id: UUID; var kind: ItemKind; var layer: ItemLayer; var frame: Rect; var rotation: Double?; var z: String
    var parent: UUID?; var rec: RecordingLink?; var origin: String?; var clocks: [String: String]?
    var text: TextContent?; var blob: BlobRef?; var pixelSize: [Double]?; var orientation: Int?
    var crop: Rect?; var pageIndex: Int?; var pageSize: [Double]?
    var extra: [String: JSONValue]   // unknown fields, re-emitted verbatim
}
public struct Recording: Hashable, Sendable, Codable, Identifiable { /* format.md §8.3.1, plus extra */ }
// Page.items: [Item]; NoteState.recordings: [Recording]; Tombstones.items, .recordings; Stroke.rec
// Op: .addItem(page:item:), .removeItem(page:itemId:), .setItem(page:itemId:field:value:),
//     .addRecording(Recording), .removeRecording(recordingId:), .setRecording(recordingId:field:value:)
//     (field: String, value: JSONValue; typed accessors for the known fields)

// InkVault (B2)
extension Vault {
    public func blobName(sha256: Data) throws -> String
    public func writeBlob(contentsOf file: URL, type: String) throws -> BlobRef   // streaming
    public func writeBlob(_ data: Data, type: String) throws -> BlobRef
    public func readBlob(_ ref: BlobRef, maxBytes: Int) throws -> Data            // verified
    public func withBlobFile<T>(_ ref: BlobRef, _ body: (URL) throws -> T) throws -> T  // verified temp plaintext
    public func blobReferences() throws -> [String: Set<UUID>]                    // sha256 → note ids, whole vault
    public func collectBlobs(state: inout BlobCollectorState, now: Date, dryRun: Bool) throws -> BlobCollectionReport
}
public protocol BlobSource: Sendable {                                           // InkVault (B2); Vault conforms
    func data(for ref: BlobRef, maxBytes: Int) throws -> Data
    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T
}

// InkRender (C1–C3)
public protocol PDFPageRasterizer: Sendable { func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int) throws -> RGBAImage }
// RenderOptions gains: blobs: (any BlobSource)?, pdfRasterizer: (any PDFPageRasterizer)?, recordings: RecordingExport
// Writers gain a `report` (placeholders, warnings) output.
```

### A. Core model, ops, merge (`Sources/InkVault`; Opus)

**A0 — model types.** Types above with Codable exactly per `format.md` §8
(lowercase UUIDs, 3-decimal rounding, omitted defaults), `extra` preserved
byte-equivalently (decode → encode round trip of every `format.md` §8 example
and of an item with unknown kind and fields), `Op` encoding and decoding of
the six new ops, `setItem` field validation (immutable field → error; `null`
rules). No merge changes beyond compiling (`NoteReducer` may ignore the new
ops with a `// A1` marker; the PR must not be released alone).
*Done when:* JSON tests for every example; unknown kind/field round trip;
invalid `setItem` rejected; `swift test` green.

**A1 — merge, snapshots, history.** `NoteReducer`: items and recordings as
sets with permanent tombstones and covered-add removal; registers per (item,
field) and (recording, field) with snapshot `clocks` and the `.base` rule;
orphans for `addItem`/`setItem` (unknown page or item) and `setRecording`
(unknown recording); a removed page removes its items; snapshot output sorted
(`(layer, z, id)`, `(started, id)`), `origin` on every item and recording.
`History`: restore diff for items and recordings (present by id or `parent`
with equal immutable fields; registers via `setItem`/`setRecording`),
`RestoreSummary` counts. `NoteSummary`: item and recording counts, typed text
for search.
*Done when:* the shuffled-order property test covers items and recordings;
scenario tests: concurrent `setItem(frame)` (higher stamp wins, both orders),
move vs crop on different fields (both apply), `removeItem` vs concurrent
`setItem` (stays removed), `setItem` arriving before its `addItem` (orphan,
excluded from `included`, applied once the add arrives), late `setItem` on a
compacted-away removed item (no-op, covered), snapshot of an unknown kind
re-emitted unchanged, restore of a deleted image twice writes nothing the
second time; fixture vault gains a note with one item of each kind (B2 adds
the blobs).

### B. Blob store, rewrap, collection, sync

**B1 — Age streaming and header rewrap** (`Sources/Age`; Opus). Streaming
encrypt (input file or chunk sequence → output file), streaming decrypt
(chunk iterator that releases only authenticated chunks), and
`rewrapHeader(of:identities:to:)` that keeps the file key.
*Done when:* CCTV vectors pass through the streaming paths; a 300 MB round
trip runs with bounded memory (chunk-level API, no whole-file `Data`);
interop with the `age` CLI both ways for streamed files and for a rewrapped
header; a truncated or reordered chunk is rejected at the right chunk.

**B2 — blob store, verify, rewrap, collection, CLI** (`Sources/InkVault`,
`Sources/InkVaultCLI`; Opus). Names, framing, Padmé, write/read/verify
(streaming, via B1; start on the one-shot API if B1 is not merged),
`Vault.verify` reports blobs (`missing`, `invalid`, `unreferenced`,
`staleRecipients`, `unknownFile`), recipient change covers blobs
(header-only rewrap, rename on removal, journal fallback lookup, resumable),
`features` in `vault.json`, collection per `format.md` §8.1.6 with
device-local state (`$XDG_STATE_HOME/inkvault/blobs/<vaultId>.json`; the app
keeps its own in Application Support). CLI: `inkvault blobs list | verify |
extract SHA256 [--out] | gc [--dry-run] | repair`, `recover` extracting a
note's attachments with the stock framing.
*Done when:* tests for name binding (renamed file, swapped content,
non-zero padding, wrong length all rejected), Padmé sizes, the stock recovery
commands of `format.md` §8.1.7 against the real `age` CLI, rewrap add/remove
interrupted and resumed (names and stanza counts), collection blocked by each
of rules 1–4 separately, collection never removing a blob that a surviving
restore point needs, fixture vault with blobs.

**B3 — WebDAV sync of blobs** (`Sources/InkWebDAV`; Sonnet, Opus review).
`blobs/` collection per §4 above; streaming GET to a temp file and PUT from a
file; `maxBlobBytes` (default 1 GiB + 64 MiB) separate from `maxFileBytes`;
deletion only under rules 1–3 on the deleting side; remote names validated.
*Done when:* mock-server tests for each row of the write-once table with
blobs, a dropped-but-referenced blob is copied back, a hostile name is
ignored, a 300 MB blob syncs with bounded memory; wsgidav integration test.

### C. InkRender export

**C1 — images** (`Sources/InkRender`; Sonnet, Opus for the JPEG decoder).
Placement math (`format.md` §8.5.1 tables), PDF Image XObjects (JPEG
DCTDecode passthrough with SOF parsing; PNG decode → Flate + SMask), SVG
data URIs and `--assets`, PNG raster with a PNG decoder and a baseline +
progressive JPEG decoder (with DCT scaling), placeholders, `BlobSource`
plumbing, export report.
*Done when:* golden tests for every orientation, crop and rotation in all
three formats; JPEG decoder matches reference decodes (libjpeg-turbo output
committed as fixtures) within ±2 per channel; malformed and truncated inputs
fail cleanly (fuzz test); the 100 MP cap is enforced.

**C2 — text** (`Sources/InkRender` + font resources; Opus for layout and the
PDF font embedding). Bundled DejaVu fonts (package resources; the static CLI
artifact ships the resource bundle next to the binary, CI updated), TrueType
reader (`head`, `hhea`, `maxp`, `cmap` 4/12, `hmtx`, `loca`, `glyf`
including composite glyphs), `TextLayout` per `format.md` §8.5.3 (public: the
app uses it), PDF Type0/CIDFontType2 embedding with `ToUnicode`, SVG text,
raster glyphs.
*Done when:* layout unit tests (breaks, hyphen, long word, alignment, mixed
sizes, empty lines, tabs); `pdftotext` (poppler) extracts the typed text from
an export; golden PDF/SVG/PNG; a character outside the fonts renders the
missing-glyph box and is reported.

**C3 — PDF backgrounds** (new target `Sources/InkPDF`, `Sources/InkRender`;
Opus). The reader subset of §10, page boxes and count, Form XObject import,
`PDFWriter` 1.7 when embedding, SVG/PNG placeholders or `PDFPageRasterizer`.
*Done when:* fixtures covering classic xref, xref stream + object streams,
incremental update, broken xref (repair), inherited boxes and `/Rotate` 90,
encrypted (refused); exported PDFs open in poppler (`pdftoppm`) with the
background in the right place (pixel comparison against `pdftoppm` of the
source page, small tolerance); the fuzz test never crashes; portability
check passes.

**C4 — recordings in exports** (`Sources/InkRender`, `Sources/InkVaultCLI`;
Sonnet). `--recordings none|list|attach`, the list page (uses C2's text),
PDF embedded files, `export --format media`.
*Done when:* `pdfdetach -list` shows the attached audio; the list page shows
title, date, duration, transcript.

### D. Notability import (`Sources/InkImport`; Opus for reverse engineering, Sonnet after)

Each starts by answering its unknowns in §11 on the user's backup (findings go
into `docs/import-notability.md`, never the data itself) and by extending the
synthetic `.note` fixture so CI covers the mapping.

- **D1 — PDF backgrounds** (needs C3's `InkPDF` for page boxes; can start
  with `pageSize` from thumbnails). *Done when:* the 26 PDF notes import with
  their pages at the right bands (`RealNotabilityTests` checks recognition
  origins still align; the eval oracle compares with PDF-composited
  thumbnails), `dropped.pdfPages` is 0, template PDFs handled or reported.
- **D2 — images.** *Done when:* the 4 image notes import their images where
  the thumbnails show them; non-JPEG/PNG reported.
- **D3 — typed text.** *Done when:* synthetic fixture with styled text maps
  to runs; real notes with text import it (if the backup has any).
- **D4 — recordings and ink sync.** *Done when:* recordings import with
  duration and title; strokes carry `rec` where `eventTokens` (or the newer
  equivalent) say so, verified by listening to a sample.

### E. App (`Apps/`; Opus for E0/E3, Sonnet for the rest)

- **E0 — attachment plumbing:** `NoteWriter.addBlob`, `BlobCache` (verified
  temp plaintext files, LRU, cleared on lock), lazy iCloud download of
  referenced blobs, `ItemLayerView` between `PaperView` and the canvas with
  placeholders, item selection/move/resize/rotate/delete overlay, items in
  undo. *Done when:* app tests with an in-memory vault cover add/move/delete
  through `NoteWriter`; one delta per gesture; iCloud logic tests in
  `CloudScan` style.
- **E1 — images:** Photos picker, camera, paste/drop, HEIC → JPEG, metadata
  stripping, orientation, crop UI. *Done when:* a HEIC with GPS becomes a
  JPEG blob without APP1; orientation 6 photo displays upright.
- **E2 — text boxes:** text tool, editor overlay, styles (bold, italic,
  underline, colour, size, alignment, family), committed text through
  `TextLayout`, search hits highlighted. *Done when:* text typed on iPad
  exports with identical line breaks (snapshot test of line ranges).
- **E3 — PDF import and backgrounds:** import as a new note or insert pages,
  unlock/decrypt, tiled display, `PDFPageRasterizer`. *Done when:* a
  200-page PDF imports, scrolls and zooms without memory warnings on the
  simulator; encrypted PDF flow tested.
- **E4 — recording and playback:** record (segmented), background audio,
  interruptions, list per note, playback with ink highlighting, tap stroke to
  seek, `rec` on strokes and items. *Done when:* recording survives a
  simulated interruption; `rec.at` within 0.1 s in a scripted test; tested on
  the user's iPad (A12Z, 26.7.1).
- **E5 — transcription:** SpeechTranscriber → DictationTranscriber →
  SFSpeechRecognizer on-device fallback, locale and asset checks, transcript
  view, tap word to seek, search. *Done when:* availability matrix verified on
  the user's iPad and recorded in `docs/`; transcript JSON validates against
  `format.md` §8.3.2.

### F. CLI and search (`Sources/InkVaultCLI`; Sonnet)

`notes show` lists items and recordings; `search` covers typed text and
(`--transcripts`) transcripts; `export` wires the vault as `BlobSource`;
`import pdf FILE` (needs C3) and `attach image|audio NOTE FILE` for scripted
use and tests. *Done when:* end-to-end CLI tests: import a PDF, attach an
image and audio, export PDF with backgrounds and attachments, search finds
typed text.

### Dependencies

```
A0 ──► A1
A0 ──► B2 ──► B3          B1 ──► B2 (B2 may start on one-shot Age)
A0 ──► C1, C2, C3, C4     (C* need BlobSource from B2: stub it in tests)
C3 ──► D1 (InkPDF); A0 ──► D2, D3, D4 (write through B2)
A1 + B2 ──► E0 ──► E1, E2, E3, E4 ──► E5
C2 ──► E2 (TextLayout), C4
A1 + B2 + C* ──► F
```

## 15. Decisions to confirm

The PR description lists these with a recommendation each; they are the
choices that are expensive to change once data exists.

1. Vault-wide content-addressed `blobs/` (vs per-note).
2. Keyed blob names that double as the integrity tag; no tag inside blobs.
3. Header-only rewrap of blobs on recipient changes (keep file keys).
4. Padmé padding of blobs.
5. Mutable items with LWW registers (vs immutable remove + add).
6. Ink above all items; two item layers; backgrounds hide ruling.
7. Minimal rich text; bundled DejaVu fonts used by both app and exports.
8. AAC-LC in MP4, mono, 48 kHz, 64 kbit/s.
9. Transcripts as separate blobs; on-device only, opt-in.
10. Audio-ink sync via immutable `rec` on strokes and items.
11. Open item kinds and fields (degrade to placeholders); ops stay fail-closed.
12. PDF import: one finite page per PDF page; Notability: bands.
13. PDF backgrounds in SVG/PNG on Linux are placeholders.
14. Recordings in PDF exports: off by default; `list` and `attach` options.
15. Collection: explicit, with a device-local 30-day grace; the residual race.
16. Limits (1 GiB blobs, 64 KiB text items, 100 MP images).
17. Image metadata stripped; HEIC converted.
18. `features` in `vault.json`.
19. `DESIGN.md`: typed text boxes and audio leave the non-goals.
