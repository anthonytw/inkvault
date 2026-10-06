# Plan

## Phase 0 — core library and CLI (Linux-buildable, cloud-friendly)

| # | Task | Owner target | Done when |
| --- | --- | --- | --- |
| 0.1 | age v1: X25519 + scrypt recipients, header, HMAC, STREAM payload, armor, Bech32 keys | `Sources/Age` | all C2SP CCTV vectors pass; round-trips with the `age` CLI |
| 0.2 | Vault: manifest, keys, vault secret, body framing + tag, revisions, HLC, merge, snapshot, compaction; on-disk vault I/O (`docs/io.md`) | `Sources/Sempere` | property tests for merge; concurrent-edit scenarios; `format.md` examples parse; vault round trip, tag binding, resumable recipient rewrap, `age -d … \| tail -c +38 \| gunzip` recovery test; fixture vault in `Tests/SempereTests/Fixtures` |
| 0.3 | Render: B-spline evaluation, variable-width outlines, paper, PDF writer, SVG writer | `Sources/SempereRender` | golden-file tests; PDF opens in Preview; matches PencilKit interpolation on macOS |
| 0.4 | CLI: `keys`, `vault init/info/recipients/verify`, `notes`, `export`, `recover`, `compact`, `snapshot` (done, `docs/cli.md`) | `Sources/SempereCLI` | end-to-end test: init → write revisions → export PDF → `age -d` recovery |
| 0.5 | CI: Linux (swift:6.4-noble) + macOS; static Linux CLI artifact; cloud setup script | `.github`, `scripts` | green on PR, binary downloadable |
| 0.6 | Notability importer: `.note` packages (and Notability's Google Drive backup zip) to notes, including Notability's recognised handwriting as page recognition (`docs/import-notability.md`); CLI `import notability` (done, `docs/cli.md`) | `Sources/SempereImport`, `Sources/SempereCLI` | synthetic `.note` fixture tested in CI; whole personal backup imports; rendered output checked against Notability thumbnails |
| 0.7 | CLI `search` over page recognition text (done, `docs/cli.md`; matching note title, notebook and tags is not implemented) | `Sources/SempereCLI` | end-to-end test: import fixture → search finds a recognised word |
| 0.8 | Interop fixture vault committed under `Tests/Fixtures` with a throwaway key | tests | every target can load it |

## Phase 1 — iPad app

Xcode project under `Apps/`. SwiftUI shell; PencilKit canvas with the system
tool picker; paper layer; notebook/tag sidebar; autosave to the note log;
vault location picker (on device, iCloud Drive, Files-app folder); key
generate/import (AirDrop, QR, paste)/export; PDF share sheet; Face ID unlock;
on-device handwriting recognition (Vision `VNRecognizeTextRequest` on
rendered pages, iPadOS 26) writes page recognition (`format.md` §5.5); search
UI over it (done: `PageRecognizer.swift`, `NoteEditor` recognition,
`AppModel+Search.swift`, `Sources/Sempere/NoteSearch.swift`).

## Phase 2 — Mac companion

Same target via Catalyst: menus, keyboard shortcuts, multi-window, drag and
drop export, key management, pointer input (`docs/mac.md`; bulk export from
the app comes with the share/export work).

## Phase 3 — nice to have

Built-in WebDAV client (`sempere sync webdav`, `docs/io.md`; the iPad app UI
is still open); compaction UI;
~~PNG export~~ (done: `sempere export --format png [--dpi N]`, pure-Swift rasterizer in
`Sources/SempereRender`, `docs/cli.md`); page backgrounds (PDF and image attachments: in the reference
Notability backup 26 of 130 notes are annotated PDFs and 4 hold images, all
imported today as ink on blank paper; now designed with text boxes and audio,
see "Attachments" below); stroke
dedupe after concurrent slicing; ~~post-quantum recipient type~~ (done:
MLKEM768-X25519, `docs/post-quantum.md`); read-only
access to vaults of a newer format version (`format.md` §7; today `Vault.open`
refuses any `format` other than `sempere/1`).

Done from this list:

- **Recovery kit and backups** (`docs/cli.md` "Keys" and "Backup and restore",
  `DESIGN.md` "Recovery"): `sempere keys paper` prints the key (or the
  passphrase-wrapped key file) as a QR code and checked text with stock-tool
  recovery steps; `sempere backup` (incremental folder or tar), `backup
  verify`, `restore`. Still to do: the same kit and a backup button in the app.

- **History and restore, core + CLI** (`Sources/Sempere/History.swift`,
  `format.md` §5.7, `docs/cli.md`): restore points per revision, the note as of
  any revision, `Vault.restore` writing one delta (re-added items get new ids
  with `parent`), `sempere notes history`, `notes restore --to [--dry-run]`,
  `export --at`. Compacted revisions are not restore points. Still to do: the
  history browser UI in the app (Phase 1/2), on top of `Vault.restorePoints`,
  `Vault.state(noteId:at:)` and `Vault.restore`.

## Attachments (typed text, images, audio, PDF pages)

Design: `docs/attachments.md` (rationale, task details and acceptance
criteria) and `docs/format.md` §8 (normative). Status: **decisions final**
(`docs/attachments.md` §16); no task starts before the design PR merges. A0
goes first; after it, the rest run in parallel along the dependencies in
`docs/attachments.md` §14. G1, G2 and L are future work and block nothing.

| # | Task | Owner target | Depends on | Done when (summary) |
| --- | --- | --- | --- | --- |
| A0 | Model types: items (integer layers), recordings, transcripts, blob refs, text (Unicode, `breaks`), `rec`, six ops, open fields (`JSONValue`). **Done (#47)**: `Sources/Sempere/Attachments.swift`, `JSONValue.swift`; snapshots refuse attachments until A1 | `Sources/Sempere` | — | every `format.md` §8 example round-trips; unknown kinds/fields/layers re-emitted verbatim |
| A1 | Merge, snapshots, tombstones, orphans, history/restore, summaries | `Sources/Sempere` | A0 | shuffled-order property test with items; concurrency scenarios of §14 |
| B1 | Age streaming encrypt/decrypt, header-only rewrap, streaming re-encrypt (PR #43) | `Sources/Age` | — | CCTV via streaming; 300 MB bounded-memory round trip; `age` CLI interop |
| B2 | Per-note blob store (`notes/<id>/att/`): names, kinds, framing, Padmé, verify, copy, rewrap policy (header-only on add, re-encrypt on removal/PQ) + rename, per-note collection, `sempere blobs …` | `Sources/Sempere`, CLI | A0 (B1) | binding tests; stock-tool recovery test; both rewrap methods resumable; GC rules 1–4 each tested per note |
| B3 | WebDAV sync of each note's `att/` (streaming, own size limit, GC-safe deletes) | `Sources/SempereWebDAV` | B2 | write-once table tests with blobs; 300 MB blob with bounded memory |
| C1 | Export images (DCT passthrough with metadata stripped, PNG/JPEG decoders, SVG data URIs, HEIC placeholder). **In review (#62)**: `JPEG.swift`, `PNGDecoder.swift`, `Items.swift`, writers; blob reading (`Sources/Sempere/Blobs.swift`, read side of B2) | `Sources/SempereRender` | A0 | golden tests for orientations/crops/rotation; decoder fixtures; fuzz |
| C2 | Export text: full Unicode (Noto + optional font packs, OpenType reader, UAX #9/#14/#29, small shaper, stored `breaks`, font **subsets** in PDF/SVG, missing-script report) | `Sources/SempereRender` | A0 | layout tests incl. RTL; CJK via font pack in `pdftotext`; subset-only fonts; goldens |
| C3 | `SemperePDF` minimal reader + PDF backgrounds as Form XObjects; SVG/PNG via optional Poppler (`pdftoppm`) process, else placeholder + warning | `Sources/SemperePDF`, `Sources/SempereRender`, CLI | A0 | xref/objstm/incremental/repair fixtures; poppler pixel check; hung/crashing renderer handled; fuzz |
| C4 | Recordings in exports (`--recordings list` / `attach`, `--format media`) | `Sources/SempereRender`, CLI | C2 | `pdfdetach` lists audio |
| D1 | Notability PDF backgrounds | `Sources/SempereImport` | C3 | 26 PDF notes import with their pages; `dropped.pdfPages` 0 |
| D2 | Notability images | `Sources/SempereImport` | A0, B2 | 4 image notes match thumbnails |
| D3 | Notability typed text | `Sources/SempereImport` | A0 | styled synthetic fixture maps to runs |
| D4 | Notability recordings + ink sync | `Sources/SempereImport` | A0, B2 | recordings import; strokes carry `rec` |
| E0 | App plumbing: `NoteWriter.addBlob`/`copyBlob`, blob cache, lazy per-kind iCloud download, item layer + selection | `Apps/` | A1, B2 | one delta per gesture; app tests |
| E1 | App images (Photos, camera, paste, privacy setting: HEIC→JPEG + metadata stripping on by default, crop) | `Apps/` | E0, C1 | GPS-free JPEG blobs by default; orientation correct |
| E2 | App text boxes (system fonts, any script, RTL, `breaks` from TextKit, CoreText `TextShaper` for exports) | `Apps/` | E0, C2 | same line breaks app vs app export vs CLI export |
| E3 | App PDF import, tiled backgrounds, PDFKit rasterizer | `Apps/` | E0, C3 | 200-page PDF, no memory warnings |
| E4 | App recording (configurable codec/quality) + playback + ink sync; export sheet "PDF" / "PDF + attachments" | `Apps/` | E0 | interruption test; tested on the user's iPad |
| E5 | App on-device transcription (segments + word timings/confidence, read-back highlighting) | `Apps/` | E4 | availability matrix on the user's iPad recorded |
| E6 | App **Settings panel**: recording format, photo privacy, transcription, device-key rewrap modes (add; remove/PQ), storage | `Apps/` | E0 (E7 for storage) | defaults match `docs/attachments.md` §15; each setting tested |
| E7 | App **attachment index** + "Unused attachments: N items, X MB" browsable list (preview, note history, delete after 30 days) | `Apps/` | E0, A1, B2 | per-note updates only; 30-day window and reset tested |
| F | CLI: `notes show`, `search` (text, transcripts), `import pdf`, `attach`, export wiring | `Sources/SempereCLI` | A1, B2, C* | end-to-end CLI test |
| G1 | *Future:* `math` items (LaTeX source, typeset on device with SwiftMath/MIT, rendered PDF blob); handwriting→LaTeX later, on device | `Apps/`, `Sources/` | C3, E2 | format §8.2.7 defined; exports embed the rendering |
| G2 | *Future:* `video` items (blob kind `video`, 1 GiB cap, poster, AVPlayer, attached in "PDF + attachments") | `Apps/`, `Sources/` | E4 | format §8.2.7 defined |
| L | *Future:* app UI localization with String Catalogs, Spanish first; contributions welcome | `Apps/` | — | Spanish catalog complete; contributor guide |

## Working agreements

- One task → one branch → one PR → squash merge. CI must be green.
- `Sources/` never imports UIKit, AppKit, PencilKit, CoreGraphics or
  Compression. Linux CI enforces it by failing to build.
- Format changes go through `docs/format.md` first.
- Spawned agents: Sonnet 5.5 by default, Opus 5.5 for crypto and merge logic.
