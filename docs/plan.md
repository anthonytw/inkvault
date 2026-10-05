# Plan

## Phase 0 — core library and CLI (Linux-buildable, cloud-friendly)

| # | Task | Owner target | Done when |
| --- | --- | --- | --- |
| 0.1 | age v1: X25519 + scrypt recipients, header, HMAC, STREAM payload, armor, Bech32 keys | `Sources/Age` | all C2SP CCTV vectors pass; round-trips with the `age` CLI |
| 0.2 | Vault: manifest, keys, vault secret, body framing + tag, revisions, HLC, merge, snapshot, compaction; on-disk vault I/O (`docs/io.md`) | `Sources/InkVault` | property tests for merge; concurrent-edit scenarios; `format.md` examples parse; vault round trip, tag binding, resumable recipient rewrap, `age -d … \| tail -c +38 \| gunzip` recovery test; fixture vault in `Tests/InkVaultTests/Fixtures` |
| 0.3 | Render: B-spline evaluation, variable-width outlines, paper, PDF writer, SVG writer | `Sources/InkRender` | golden-file tests; PDF opens in Preview; matches PencilKit interpolation on macOS |
| 0.4 | CLI: `keys`, `vault init/info/recipients/verify`, `notes`, `export`, `recover`, `compact`, `snapshot` (done, `docs/cli.md`) | `Sources/InkVaultCLI` | end-to-end test: init → write revisions → export PDF → `age -d` recovery |
| 0.5 | CI: Linux (swift:6.4-noble) + macOS; static Linux CLI artifact; cloud setup script | `.github`, `scripts` | green on PR, binary downloadable |
| 0.6 | Notability importer: `.note` packages (and Notability's Google Drive backup zip) to notes, including Notability's recognised handwriting as page recognition (`docs/import-notability.md`); CLI `import notability` (done, `docs/cli.md`) | `Sources/InkImport`, `Sources/InkVaultCLI` | synthetic `.note` fixture tested in CI; whole personal backup imports; rendered output checked against Notability thumbnails |
| 0.7 | CLI `search` over page recognition text (done, `docs/cli.md`; matching note title, notebook and tags is not implemented) | `Sources/InkVaultCLI` | end-to-end test: import fixture → search finds a recognised word |
| 0.8 | Interop fixture vault committed under `Tests/Fixtures` with a throwaway key | tests | every target can load it |

## Phase 1 — iPad app

Xcode project under `Apps/`. SwiftUI shell; PencilKit canvas with the system
tool picker; paper layer; notebook/tag sidebar; autosave to the note log;
vault location picker (on device, iCloud Drive, Files-app folder); key
generate/import (AirDrop, QR, paste)/export; PDF share sheet; Face ID unlock;
on-device handwriting recognition (PencilKit, iPadOS 27) writes page
recognition (`format.md` §5.5); search UI over it.

## Phase 2 — Mac companion

Same target via Catalyst: menus, keyboard shortcuts, multi-window, drag and
drop export, bulk export, key management.

## Phase 3 — nice to have

Built-in WebDAV client (`inkvault sync webdav`, `docs/io.md`; the iPad app UI
is still open); compaction UI;
~~PNG export~~ (done: `inkvault export --format png [--dpi N]`, pure-Swift rasterizer in
`Sources/InkRender`, `docs/cli.md`); page backgrounds (PDF and image attachments: in the reference
Notability backup 26 of 130 notes are annotated PDFs and 4 hold images, all
imported today as ink on blank paper; now designed with text boxes and audio,
see "Attachments" below); stroke
dedupe after concurrent slicing; post-quantum recipient type; read-only
access to vaults of a newer format version (`format.md` §7; today `Vault.open`
refuses any `format` other than `inkvault/1`).

Done from this list:

- **History and restore, core + CLI** (`Sources/InkVault/History.swift`,
  `format.md` §5.7, `docs/cli.md`): restore points per revision, the note as of
  any revision, `Vault.restore` writing one delta (re-added items get new ids
  with `parent`), `inkvault notes history`, `notes restore --to [--dry-run]`,
  `export --at`. Compacted revisions are not restore points. Still to do: the
  history browser UI in the app (Phase 1/2), on top of `Vault.restorePoints`,
  `Vault.state(noteId:at:)` and `Vault.restore`.

## Attachments (typed text, images, audio, PDF pages)

Design: `docs/attachments.md` (rationale, task details and acceptance
criteria) and `docs/format.md` §8 (normative). Status: **design under
review**; no task starts before the design PR merges. A0 goes first; after
it, the rest run in parallel along the dependencies in
`docs/attachments.md` §14.

| # | Task | Owner target | Depends on | Done when (summary) |
| --- | --- | --- | --- | --- |
| A0 | Model types: items, recordings, blob refs, text, `rec`, six ops, open fields (`JSONValue`) | `Sources/InkVault` | — | every `format.md` §8 example round-trips; unknown kinds/fields re-emitted verbatim |
| A1 | Merge, snapshots, tombstones, orphans, history/restore, summaries | `Sources/InkVault` | A0 | shuffled-order property test with items; concurrency scenarios of §14 |
| B1 | Age streaming encrypt/decrypt, header-only rewrap | `Sources/Age` | — | CCTV via streaming; 300 MB bounded-memory round trip; `age` CLI interop |
| B2 | Blob store: names, framing, Padmé, verify, rewrap + rename, collection, `inkvault blobs …` | `Sources/InkVault`, CLI | A0 (B1) | binding tests; stock-tool recovery test; GC rules 1–4 each tested |
| B3 | WebDAV sync of `blobs/` (streaming, own size limit, GC-safe deletes) | `Sources/InkWebDAV` | B2 | write-once table tests with blobs; 300 MB blob with bounded memory |
| C1 | Export images (DCT passthrough, PNG/JPEG decoders, SVG data URIs) | `Sources/InkRender` | A0 | golden tests for orientations/crops/rotation; decoder fixtures; fuzz |
| C2 | Export text (bundled DejaVu, TrueType reader, `TextLayout`, PDF Type0 + ToUnicode) | `Sources/InkRender` | A0 | layout tests; `pdftotext` finds the text; goldens |
| C3 | `InkPDF` minimal reader + PDF backgrounds as Form XObjects | `Sources/InkPDF`, `Sources/InkRender` | A0 | xref/objstm/incremental/repair fixtures; poppler pixel check; fuzz |
| C4 | Recordings in exports (`--recordings list` / `attach`, `--format media`) | `Sources/InkRender`, CLI | C2 | `pdfdetach` lists audio |
| D1 | Notability PDF backgrounds | `Sources/InkImport` | C3 | 26 PDF notes import with their pages; `dropped.pdfPages` 0 |
| D2 | Notability images | `Sources/InkImport` | A0, B2 | 4 image notes match thumbnails |
| D3 | Notability typed text | `Sources/InkImport` | A0 | styled synthetic fixture maps to runs |
| D4 | Notability recordings + ink sync | `Sources/InkImport` | A0, B2 | recordings import; strokes carry `rec` |
| E0 | App plumbing: `NoteWriter.addBlob`, blob cache, lazy iCloud, item layer + selection | `Apps/` | A1, B2 | one delta per gesture; app tests |
| E1 | App images (Photos, camera, paste, HEIC→JPEG, crop) | `Apps/` | E0, C1 | GPS-free JPEG blobs; orientation correct |
| E2 | App text boxes (editor overlay, styles, `TextLayout` display) | `Apps/` | E0, C2 | identical line breaks app vs export |
| E3 | App PDF import, tiled backgrounds, rasterizer | `Apps/` | E0, C3 | 200-page PDF, no memory warnings |
| E4 | App recording + playback + ink sync | `Apps/` | E0 | interruption test; tested on the user's iPad |
| E5 | App on-device transcription | `Apps/` | E4 | availability matrix on the user's iPad recorded |
| F | CLI: `notes show`, `search` (text, transcripts), `import pdf`, `attach`, export wiring | `Sources/InkVaultCLI` | A1, B2, C* | end-to-end CLI test |

## Working agreements

- One task → one branch → one PR → squash merge. CI must be green.
- `Sources/` never imports UIKit, AppKit, PencilKit, CoreGraphics or
  Compression. Linux CI enforces it by failing to build.
- Format changes go through `docs/format.md` first.
- Spawned agents: Sonnet 5.5 by default, Opus 5.5 for crypto and merge logic.
