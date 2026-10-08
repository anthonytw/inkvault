# Changelog

All notable changes to Sempere are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the CLI's version
(`Sources/SempereCLI/Version.swift`) follows [Semantic Versioning](https://semver.org/).
The section for a version is the body of its GitHub Release (`docs/releasing.md`).

## [Unreleased]

### Added

- Keys (2026-10-07 request). Web viewer: an opt-in "Remember this key on this device with a passkey".
  A WebAuthn passkey with the PRF extension (user verification required) yields a secret that HKDF turns
  into an AES-256-GCM key; only the encrypted key, its nonce, the PRF salt and the credential id go to
  IndexedDB. "Unlock with passkey" is one prompt; "Forget this key" deletes the record. Without PRF the
  viewer explains why and stores nothing. App: Settings → Device Keys → "Save Key…" exports this device's
  key after Face ID to Files or the share sheet (for a password manager), with its paper recovery kit;
  "New Key…" makes a key for another device, encrypts the vault to it and offers the same. Key files are
  the CLI's format (`keys generate`), written only where the user chooses; the share sheet's copy is
  deleted when it closes.
- Read-only access to vaults of a newer format version (`format.md` §7). A vault whose `vault.json`
  names a later `format` (`sempere/2`) or an unknown extension, and revisions marked as written by a
  newer version, no longer stop this version: it shows everything it understands (unknown ops, fields
  and snapshot elements are skipped, a later body version is left out, each reported) and never writes.
  CLI: reading commands report `readOnly`, `readOnlyReasons` and per-note `newer` in `--json`; every
  write exits 7. App: a read-only banner, notes open read-only, no autosave, thinning, inbox adoption or
  transcripts. The web viewer opens such vaults too.

- CLI: `sempere sync webdav --push-only [--delete-extraneous]`, a one-way mirror for a server that is not
  trusted to write back. It uploads, overwrites the server's `vault.json` / `rewrap-journal.json` from the local
  copy, and follows local compaction and blob collection with deletions on the server; it never downloads and
  never changes the vault (a compromised server cannot feed an attacker's recipient back). Files only the server
  has and nothing explains are reported as `extraneous` (new in `--json`, with `overwritten`) and removed with
  `--delete-extraneous`.
- A note open in the app picks up what another device writes to it (iCloud Drive, any sync, the CLI)
  without being reopened: the new revisions are downloaded and merged into the open canvas, pages,
  items, text boxes and recordings. Ink not saved yet is saved first and kept; only pages whose ink
  changed are redrawn, at the same scroll and zoom; nothing is written back for the merge. A small
  "Updated from another device" notice shows for a few seconds.
- Equations (task G1, `format.md` §8.2.8): `math` items hold LaTeX source, display or inline style,
  size, colour and a typeset PDF rendering. App: Insert → Equation… and "Edit Equation…" open a sheet
  with a live SwiftMath preview; the rendering is stored, so exports, the CLI and the web viewer draw
  the equation without a typesetter. CLI: `sempere attach math --latex '…'` (`--inline`, `--size`,
  `--color`, `--render FILE.pdf`), `sempere items math`, equations in `items list`, `notes show` and
  `search`; exports embed the rendering (PDF form; SVG/PNG via Poppler), else draw the source with a
  warning, and Markdown/HTML keep the source as `$$…$$`. LaTeX sources are bounded (8 KiB, 4 096
  symbols, 64 levels) before anything parses them.
- App polish round 1 (TestFlight build 4 feedback). The notebook field of a new note and of Move to
  Notebook is a combo box: type a new `/`-separated path or pick an existing notebook from a list that
  narrows as you type. "Recognize All Notes" ends with "Recognized N notes" and keeps the notes it changed
  (title, pages read) under "Recently Recognized" in the sidebar until the next run. A note opened from a
  search result highlights the matching words on the page (from the recognition boxes) with previous and
  next buttons across all pages and a "3 of 12 matches" count. Drag notes (several, in Select mode) onto
  a notebook or All Notes in the sidebar to move them, drag a notebook onto another to nest it or onto
  All Notes to un-nest it, or use "Move Notebook To…"; a notebook cannot go into itself or a notebook
  inside it, the drop target highlights, and each drop is one commit with one undo step. CLI:
  `sempere search --show-boxes` (match locations, numbered across the note), `sempere notebooks move NOTEBOOK PARENT`.
  Word boxes that cannot be drawn (not finite, beyond 10⁹ points, negative size) are never
  highlighted or listed (`format.md` §5.5).
- CLI: `sempere items list|move|rotate|front|delete|duplicate|copy`, the app's item gestures (one
  delta each, through the same `NoteOps` builders; `copy` copies attachments to the other note first).
- Attachment plumbing in the app (task E0, `docs/attachments.md` §13–14): a note's images, text
  boxes and PDF pages are drawn between the paper and the ink (a placeholder while a blob
  downloads or when it is missing), and Select Items mode selects, moves, resizes, duplicates,
  copies and pastes (between notes too), brings to front and deletes them, each gesture one
  delta with undo. In iCloud Drive a note's attachments download on demand: images and PDF
  pages when a page shows them, never with the note. The shared `NoteOps` item builders and
  `ItemRaster` (one item drawn as the exports draw it) are in the library for the CLI too.
- `sempere recognize [ID…|--all] [--missing-only|--force] [--dry-run]` reads handwriting with
  Vision on macOS and stores it as page recognition, one delta per note, with the app's code (page
  selection `RecognitionPolicy.pagesToRead`, image plan `RecognitionImage`, Vision mapping
  `VisionText`, now shared by both). `import notability --recognize missing` does it right after
  an import for pages Notability never indexed. Notability's recognition is replaced only with
  `--force`. The Linux build refuses with a clear message (`--dry-run` works).
- `sempere notes search QUERY`: the app's search (titles, tags, notebooks, recognised text; all
  words; ranked) with `--notebook`, `--tag`, `--deleted` and `--json`.
- Version history round 2 (`docs/format.md` §5.8): **checkpoints** (named versions:
  `sempere notes checkpoint NOTE [--name TEXT]`, the app's Save Version in the note toolbar and
  the Mac Note menu), **editing sessions** (the app records one id per opening of a note;
  `sempere notes history --sessions` and the app's history list group autosaves into sessions
  under the checkpoints, collapsed), and **thinning** (`sempere compact --thin-older-than 30d
  [--dry-run]`; in the app a setting, default 30 days or never, a daily automatic run and Thin
  Now with a preview): old autosaves go, every checkpoint and the newest autosave of each
  session stay restorable, the note's state never changes. `compact` never deletes a checkpoint
  and keeps it restorable, and keeps a note's first revision while device clocks disagree (an
  older revision with a later `wall`), so the note's creation date cannot move.
- Web viewer: attachments (`docs/web-viewer.md`, `format.md` §8). Images (orientation, crop,
  rotation, metadata stripped), text boxes laid out with their stored line breaks and the
  format's line metrics, PDF pages drawn by a pinned pdf.js (worker and font data served by the
  viewer itself; no font loading, scripts or annotations), placeholders for unknown kinds and for
  missing, invalid or undrawable blobs (listed with the reason), and a note's recordings with
  playback and transcripts. Blobs are read only when their item comes on screen (audio when
  played), decrypted as a stream and checked before use: framing, zero padding, content hash and
  the keyed name. The Content-Security-Policy gains `blob:` images and media, a same-origin
  worker and one Trusted Types policy for it. Cross-checked against the CLI's SVG export of new
  synthetic fixture notes.
- Notability import of attachments (tasks D1, D2, `docs/import-notability.md` "Attachments"):
  the PDF pages of a note made from a PDF become page backgrounds (`pdfPage` items backed by the
  original PDF, laid out from the PDF's own page boxes), and images become image items with
  their frame, rotation and crop, metadata stripped. `sempere import notability` gains
  `--no-attachments` and `--keep-image-metadata`, and reports what it placed (`attachments`)
  and why anything was left out (`warnings`).
- Notability import of typed text and recordings (tasks D3, D4): typed text becomes text items
  with bold, italic, underline, strikethrough, colours and sizes as runs (and `lang` for CJK,
  Arabic and Hebrew runs); `Recordings/` becomes the note's recordings with their audio, and
  strokes link to the recording (`rec`) where `eventTokens` read as times in it.
- Attachments from the command line (task F, `docs/cli.md` "Adding attachments"): `sempere attach
  image|pdf|text|recording|transcript` add an image, PDF pages (as new background pages or as a
  figure), a text box, an MPEG-4 recording or a transcript to a note, each as one delta with
  `--json` output; `sempere import pdf` makes a note from a PDF, one page per PDF page with the
  page as its background; `sempere search` also searches the text of text boxes and, with
  `--transcripts`, transcripts; Markdown and HTML exports include typed text. The logic is shared
  with the app: `NoteOps` placement builders, `AudioProbe` (MPEG-4 header reader), `ImageIngest`
  and `PDFIngest`.
- Attachment merge (task A1, `docs/format.md` §5.3, §8.2.2, §8.3.1): placed items and recordings
  merge as sets with permanent tombstones, orphans and covered-add removal, and their fields as
  last-writer-wins registers (unknown fields included), in the library and the web viewer.
  Snapshots, `compact`, history and `notes restore` now keep them (restore re-creates removed
  items and recordings with `parent`; a moved item goes back to its page). Summaries count items
  and recordings, list the blobs a note references, and make text boxes searchable.
  `sempere notes show` lists items and recordings (`items`, `recordings` in `--json`; `notes list
  --json` counts them).
- iPhone app, as a reader (`docs/iphone.md`): the app target now also runs on iPhone. The vault,
  its notebooks and tags, the note list and the note are a stack; a note opens for reading (pan,
  zoom, page bar) and the pencil button switches on light finger annotation. Search, export,
  version history and Face ID unlock work as on the iPad. The iPad and the Mac are unchanged.
  iPhone 6.9" App Store screenshots: `scripts/screenshots.sh iphone`.
- **Paged and pageless notes** (`docs/format.md` §5.4.3, #52): a note has fixed-size pages
  or one infinite page, and switches between them without deleting or moving ink
  (`sempere notes layout ID paged|pageless`; in the app, the Page Layout menu). In the app,
  paged notes add a page after the current one or at the end, delete (with undo),
  duplicate, and reorder pages by dragging in a thumbnail strip; each gesture is one delta.
  The CLI has the same gestures: `sempere pages add --after`, `move`, `delete`, `duplicate`.
  Recognised text that moves with its ink keeps its `basis`, so it is not read again (or is,
  when it was stale).
- CLI parity with the app's note browser and canvas: `sempere notes new`, `rename`, `tag`
  (`--add`/`--remove`), `move`, `paper` (whole note or `--page N`, every parametric kind and
  parameter), `delete`, `undelete`; `sempere notebooks list` / `rename` (the whole subtree);
  `sempere tags list`; `sempere pages list` / `add`. Each edit is one delta through the same core
  code as the app (`NoteOps`, `Vault.apply`), with `--json`. Policy: the CLI gets every feature
  first (`CLAUDE.md` "CLI first").
- Web viewer (`web/`, `docs/web-viewer.md`): a static, read-only page that opens a vault from a
  web server (static files or WebDAV) or a local folder, decrypts it in the browser with the
  pasted post-quantum key (typage), and shows notebooks, tags, search over titles and
  handwriting, and the notes' pages with pan and zoom, drawn exactly like the CLI's SVG export.
  The key stays in the tab's memory; strict Content-Security-Policy; no third-party requests.
- CLI: `sempere vault index` writes `sempere-index.json`, the listing the web viewer reads on a
  static server. Once written it is kept current: every command that opens the vault rewrites it
  when the listing changed, and `sync webdav` rewrites the server's copy.
- Mac app, phase 2 (`docs/mac.md`): menu bar and shortcuts from one command list, a window per
  note with state restoration, drag a note to the Finder as PDF, a key window (recipients, add
  or remove a device key, recovery kit), mouse and trackpad input (the object eraser now works
  with a pointer), an access check for saved vault folders, and sandbox entitlements for Mac builds.
- iPad app: handwriting search. Pages are read on the device with Vision after the strokes
  change (and when a note opens), the text is saved as page recognition (`format.md` §5.5, new
  optional `basis` field), and the note list searches recognised text, titles, notebooks and
  tags and opens the matching page. Recognition from a Notability import is kept until the
  page's strokes change.
- Age library: streaming encryption and decryption in constant memory (`AgeEncryptor`,
  `AgeDecryptor`, file-to-file `AgeFile.encrypt` / `decrypt`), header-only rewrap that keeps the
  file key and payload (`AgeFile.rewrapHeader`) and streaming full re-encryption
  (`AgeFile.reencrypt`), for attachments.
- Attachment blob store (`docs/format.md` §8.1; task B2): each note's `att/` holds its
  attachments' bytes as streamed, Padmé-padded age files named by a keyed hash, verified on
  every read (framing, padding, content hash, name). Recipient changes rewrap them: header only
  when a device key is added, full re-encryption and renaming when one is removed or the key
  type changes (`vault recipients … --rewrap header|reencrypt` to choose), resumable from the
  journal. New `sempere blobs list | verify | extract | add | copy | unused | gc | repair`;
  collection is per note and per device after a 30-day window; `recover` reads a single blob.
  `vault.json` gains `features: ["attachments"]` with the first blob, and a build that finds an
  unknown feature refuses to write.
- Attachment model types (`docs/format.md` §8; task A0): placed items (text, image, PDF page, and
  unknown kinds kept verbatim), recordings, transcripts, blob references and their six ops. Revisions
  holding them now decode instead of being reported unreadable (merged since A1, above).
- PDF page backgrounds in exports (attachments task C3). A new `SemperePDF` library reads PDFs
  from untrusted attachments (cross-reference tables and streams, object streams, incremental
  updates, rebuilding a broken file by scanning; bounded and fuzzed). PDF exports copy the original
  page in as a Form XObject (exact, PDF 1.7); SVG and PNG exports draw it with Poppler's
  `pdftoppm` when installed, run as a separate, time- and resource-limited process
  (`--pdf-renderer auto|poppler|none`, `--pdf-timeout`). Anything that cannot be drawn becomes a
  placeholder with a warning, never a failed export. Applies to notes once item ops are merged (A1).
- Images in exports (task C1): PDF embeds JPEGs as stored (no re-encoding) and other images
  losslessly; SVG uses data URIs or, with `export --assets DIR`, linked files; PNG export decodes
  and resamples them (pure-Swift baseline/progressive JPEG and PNG decoders). Location and camera
  metadata is removed from every exported image unless `--keep-image-metadata`. Images that
  cannot be drawn (missing attachment, HEIC in the CLI, over 100 MP) become placeholders with a
  warning. Images and PDF page backgrounds share one export report and placeholder path, and
  Markdown and HTML exports draw both.
- Text in exports (task C2): text boxes in any script, laid out per `format.md` §8.5.3 (stored line
  breaks, else UAX #14; right-to-left per UAX #9; grapheme clusters per UAX #29), shaped (Arabic
  joining and ligatures, mark attachment), drawn with the bundled Noto fonts (OFL 1.1, shipped in
  `fonts/` next to the CLI) or font packs (`$SEMPERE_FONT_DIR`, `~/.local/share/sempere/fonts`,
  system fonts). PDF and SVG embed font subsets only, with searchable text; characters no font
  covers are reported with the script and what to install.

### Changed

- Exports cut pageless pages at gaps in the ink near each sheet height instead of through
  lines of handwriting (`export --breaks gaps`, the default; `--breaks fixed` keeps the old
  cuts). Ink that a concurrent edit left below a fixed-size page is exported on an extra page
  instead of being dropped.
- `sempere notes list --notebook PATH` now lists the notes in that notebook and below it, comparing
  canonical paths by segment as the app's sidebar does (it compared raw names before).

- **Faster vault opening** (#54). Note summaries skip stroke geometry, are read in parallel,
  and are kept in an encrypted per-device cache (`docs/format.md` §10), so a 600-note vault
  lists in about 1.8 s instead of 21 s, and in 0.08 s when nothing changed. `notes list` gains
  `--no-cache`; `search` uses the same fast path. The app closes the unlock sheet as soon as the
  key is accepted, shows "Opening vault: n of m" while the list fills in, shows cached summaries
  at once on a reopen, and always says why the list is empty.

- **Instant reopen and fast note opening in the app** (#56). The note list opens from the
  encrypted local index and only notes whose revision files changed are downloaded and read
  (an iCloud vault no longer re-checks every file on every launch); a file presenter wakes the
  sync for the notes it names, a full validation runs at low priority, and list updates are
  throttled differences. Notes opened before open from an encrypted drawing cache (200 MB,
  least recently used first, deleted with the vault on this device); others are converted off
  the main thread, the strokes on screen first. Revisions decode their stroke points about twice
  as fast (same JSON). Every phase has an os_signpost interval; debug builds log timings to
  `Library/Logs/SemperePerf.log`.
- The app's Markdown export is now "Text (Markdown)": it leads with the recognised text, the
  PDF is optional (off), and it is disabled for notes without recognised text. HTML export is
  CLI-only.

- Licence: GPL-3.0-or-later with an App Store exception (`LICENSE-EXCEPTION`, a GPLv3 section 7
  additional permission). Contributions are licensed under the same terms and certified with a
  DCO sign-off; there is no contributor licence agreement.

## [0.5.0] - TODO(user): date of the first release

First public release of the `sempere` CLI. Everything below was merged before
the first tag; the pull request numbers refer to
[anthonytw/sempere](https://github.com/anthonytw/sempere/pulls).

### Added

- **age v1 encryption**, spec-exact, validated against the C2SP test vectors and
  the reference `age` CLI: X25519 and scrypt recipients, armor, Bech32 keys (#2).
- **Vault format** (`docs/format.md`): append-only note log with hybrid logical
  clock, merge, snapshots and compaction (#3); on-disk layout, body framing with
  per-vault HMAC tag, keys, note store, fixture vault (#6).
- **Rendering** to vector PDF and SVG from PencilKit-style B-splines (#1), and
  pure-Swift PNG export (`export --format png [--dpi N]`) (#13).
- **CLI** `sempere`: `keys`, `vault init/info/recipients/verify`, `notes`, `export`,
  `recover`, `compact`, `snapshot` (#7); `import notability` and `search` (#12);
  `sync webdav` with the built-in WebDAV client (#16). See `docs/cli.md`.
- **Notability importer** for `.note` packages and backup zips, including
  recognised handwriting as page recognition (#8); PDF page stride and page
  counts in the import report (#18); fidelity evaluation of every imported note (#19).
- **History and restore**: restore points per revision, `notes history`,
  `notes restore`, `export --at` (#14).
- **iPad app (in development, not released)**: Xcode project, vault shell and CI (#10);
  vault browser (#15); PencilKit canvas with stable stroke ids and autosave (#17);
  usability pass: a vault as one item in Files, progressive iCloud loading,
  tool palette, rename, tags (#21).
- **Release engineering**: tagged builds publish static Linux (x86_64, aarch64) and
  universal macOS CLI tarballs with `SHA256SUMS` and build provenance
  attestations; Homebrew formula template; CONTRIBUTING, SECURITY and App Store
  preparation docs.
- CI: Linux (`swift:6.4-noble`) and macOS test jobs, static Linux CLI build (#4),
  cloud setup script (#11).

### Fixed

- Render input validation and infinite-page output (#5).
- Two PNG and marker rendering bugs found by the import fidelity evaluation (#19).
- App: debug launch expands `~/` to the app's data container (#20).

[Unreleased]: https://github.com/anthonytw/sempere/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/anthonytw/sempere/releases/tag/v0.5.0
