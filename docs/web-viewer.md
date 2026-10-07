# Web viewer

A read-only viewer for Sempere vaults that runs entirely in the browser
(`web/`, TypeScript + Vite, no backend). It opens a vault folder of encrypted
files, decrypts them in the page with the key the user pastes, merges the
revisions into notes, and draws them. It never writes: not to the vault, not
to browser storage, not to any server.

What it does:

- **Open** a vault from an `http(s)` URL (a static file server with
  `sempere-index.json`, or a WebDAV share), from a folder picked with the File
  System Access API (Chrome, Edge), from `<input webkitdirectory>` (every
  browser), or from a folder dropped on the page.
- **Unlock** with the `AGE-SECRET-KEY-PQ-1…` identity, pasted as the bare line
  or the whole `age-keygen -pq` key file. Legacy (X25519) vaults are refused
  (`format.md` §3.3.2), as are classic `AGE-SECRET-KEY-1…` keys.
- **Browse** notebooks (the `/` hierarchy of §5.4), tags (one spelling per tag
  key, §5.4.1), favorites and deleted notes; **search** titles, tags,
  notebooks and recognised handwriting (the same rules as the app's
  `NoteSearch`: case, accents and width ignored, every word must match,
  `#word` matches tags only), with a snippet and a jump to the matching page.
- **Read** a note: pages stacked vertically, or one tall infinite page, with
  pan and zoom (wheel or trackpad, Ctrl/⌘-wheel or pinch to zoom, drag,
  arrow keys, `+` `-` `0` `1`). Paper (every kind of §5.4.2, page-level paper,
  unknown kinds drawn blank) and ink are drawn by a port of `SempereRender`, so
  a page in the viewer is the SVG that `sempere export --format svg` writes.
- **Attachments** (§8, "Attachments" below): images, text boxes and PDF pages
  in their layers under the ink, placeholders for what cannot be drawn, and
  the note's recordings with a player and their transcripts.

## How it reads a vault

The code mirrors the Swift reader and is tested against it (see "Tests").

| Step | Where | Swift counterpart |
| --- | --- | --- |
| `vault.json`: format, recipients, legacy check | `web/src/vault/vault.ts` | `Vault.readManifest` |
| age decryption (MLKEM768-X25519 stanzas) | [typage](https://github.com/FiloSottile/typage) `age-encryption` 0.3.1 | `Age` |
| `SMPR` framing, HMAC-SHA256 tag under the vault secret (WebCrypto), previous secret during a rewrap | `vault.ts` | `BodyFraming`, `NoteStore.unframe` |
| bounded gunzip (`DecompressionStream`), strict UTF-8, JSON | `web/src/vault/gzip.ts` | `Gzip.decompress` |
| revision decoding with Swift's `Codable` rules; name and content must agree (§5) | `web/src/format/model.ts`, `ids.ts`, `rfc3339.ts`, `attachments.ts` | `Model.swift`, `Revision.swift`, `Attachments.swift` |
| merge: snapshots, uncovered deltas, LWW registers, tombstones, orphans, tag OR-set with legacy baseline, items and recordings | `web/src/format/reducer.ts`, `tags.ts`, `registers.ts` | `NoteReducer`, `AttachmentRegisters` |
| B-spline sampling, ribbons, monoline, paper ruling, page extent | `web/src/render/` | `SempereRender` |
| blobs: keyed name, streaming age decryption, `INKB` framing, padding, SHA-256 (§8.1) | `web/src/vault/blobs.ts` | `BlobStore`, `Blob.swift` |
| item order, frames, rotation, crops, orientation, placeholders (§8.2.3, §8.5.1–§8.5.2) | `web/src/render/items.ts`, `itemsvg.ts` | `Items.swift`, `PageComposer` |
| JPEG and PNG headers, metadata stripping (§8.2.5) | `web/src/render/images.ts` | `JPEG.swift`, `PNGDecoder.swift` |
| text lines: stored `breaks`, line metrics, alignment, direction (§8.5.3) | `web/src/render/text.ts` | `TextLayout.swift` |
| PDF pages (§8.2.6) | pdf.js 6.4.299 (`web/src/ui/pdf.ts`) | `SemperePDF`, Poppler / PDFKit |
| transcripts (§8.3.2) | `web/src/format/transcript.ts` | `Transcript` |

Typage 0.3.1 implements the age v1.3 hybrid recipient (`mlkem768x25519`,
HPKE with X-Wing) with `@noble/post-quantum`; the viewer has no cryptography
of its own beyond calling typage and WebCrypto (HMAC-SHA256).

Unreadable revisions (wrong tag, undecryptable, undecodable) are reported in
the note view and the list ("N unreadable revisions", a "Problems" filter);
the note is shown merged from the rest, marked as such (§4: report, never
silently drop).

## Attachments

A page is drawn bottom to top as §8.2.3 says: paper, items by `(layer, z,
id)` (a background-layer item first fills its rotated frame with the paper
colour), then the ink. Each item is one of:

- **Text box**: laid out by `text.ts` with the stored `breaks` when they are
  valid (strictly increasing, inside a paragraph, on a grapheme cluster
  boundary), so the lines are the app's and the CLI's; the vertical metrics
  are the format's (line size `S` = largest run size, height `1.2 S`, baseline
  `0.95 S` below the line's top), so every line sits at the same height as in
  the exports. The glyphs are the browser's: generic families map to system
  font stacks (`sans`: system-ui, Segoe UI, Roboto, Noto Sans, Helvetica,
  Arial; `serif`: Iowan Old Style, Noto Serif, Georgia, Times; `mono`:
  ui-monospace, SF Mono, Menlo, Consolas, Noto Sans Mono), runs become
  `<tspan>`s (bold, italic, underline, strikethrough, colour, size, `lang`),
  and the browser shapes and reorders each line within its paragraph's
  direction (`dir`, or for `auto` the first letter's script). Without valid
  `breaks` the viewer breaks greedily with widths measured by the browser
  (after white space, after `-`, between wide CJK characters, and inside a
  word wider than the frame), which can differ from another renderer's lines.
- **Image** (JPEG or PNG, by signature): the header is checked first (8-bit
  baseline or progressive JPEG with 1 or 3 components, any valid PNG, at most
  100 MP and plausible for the file's size), metadata is stripped as the
  exports strip it (so an EXIF orientation in the file can never apply; the
  item's `orientation` does), and the browser decodes it from a `blob:` URL; a
  decode that fails or yields another size is a placeholder. Orientation, crop
  and rotation are one matrix, as in the CLI's SVG.
- **PDF page**: drawn by pdf.js (below) at the zoom's resolution (2 to 8
  pixels per point, at most 16 MP per item, sharpened again after zooming in),
  only the cropped part of the effective page (where a crop reaches beyond
  the page, the paper shows, as in the exports). pdf.js's effective page is
  CropBox ∩ MediaBox turned by `/Rotate`, tested against the tables of
  §8.5.1 (`test/pdf.test.ts`). Annotations are not drawn (§8.2.6).
- **Placeholder** (§8.5.2), for an unknown or reserved kind (`math`, `video`),
  a missing, unreadable or invalid blob, HEIC (no decoder in the viewer; the
  app converts photos to JPEG by default), an image or PDF it cannot draw, or
  a page index the PDF lacks. The note view lists every placeholder with its
  reason ("N items shown as placeholders").

**Blobs** (§8.1) are read only when their item comes within half a screen of
the viewport, and audio only when Play is pressed, transcripts when opened.
Each is looked up at `notes/<id>/att/<name>.<kind>.age`, with `name` keyed from
the reference's hash under the vault secret (and under the previous secret
while a rewrap is unfinished, §8.1.5), decrypted as a stream (typage checks
each 64 KiB chunk), and checked as a whole before anything is used: magic and
version, the header's hash and length equal to the reference's (which binds
the file to its keyed name), zero padding, and the SHA-256 of the content.
Content is never handed out before that. Limits: images 64 MiB, PDFs 256 MiB,
transcripts 64 MiB, audio 256 MiB (the format allows 1 GiB, §8.4, but a
browser holds the whole verified file in memory; 256 MiB is over 8 hours at
the app's default 64 kbit/s), and at most 1 MiB of padding beyond
what a writer adds. Each blob is read once per open note however many items
use it.

**Recordings** (§8.3) are listed above the pages (title, start, length). Play
decrypts the audio into an `<audio>` element (AAC in MPEG-4 plays in every
current browser except Chromium builds without proprietary codecs; ALAC only
in Safari; an unplayable format says so). A transcript is checked against
§8.3.2 (format, the recording it names, segment and word order and ranges,
confidences) and listed by segment; a segment's time plays from there, and
words under 0.5 confidence are dotted-underlined.

## Threat model

What the viewer protects, and against whom.

**Assets:** the age identity, the vault secret, and decrypted note content.

**Trusted:** the browser, the user's device, and the viewer's own files as
served (`index.html` and its hashed `assets/`). Whoever can change those files
on the server (or in transit without TLS) can change the code that receives
the key: the viewer is exactly as trustworthy as the host that serves it.
Serve it over HTTPS from a host you control, and prefer a build you made
yourself (`npm ci && npm run build`).

**Untrusted:** everything in the vault and everything the storage server
returns: file contents, listings (`sempere-index.json`, PROPFIND bodies),
sizes and names. A hostile server can withhold, replay or reorder files, but
cannot forge or alter a revision without the vault secret (the HMAC tag binds
note id, file name and body, §4), and cannot make the viewer run code:

- **No markup from data.** The UI builds DOM nodes and sets text; nothing
  parses HTML. SVG is created element by element from the renderer's
  commands, with an allow-list of element and attribute names. ESLint forbids
  `innerHTML`, `outerHTML` and `insertAdjacentHTML`.
- **Content-Security-Policy** (in the built `index.html`, and to be sent as a
  header too, below): `default-src 'none'; script-src 'self'; style-src 'self';
  img-src 'self' data: blob:; media-src blob:; connect-src 'self' [vault
  origins]; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src
  'none'; worker-src 'self'; manifest-src 'none'; require-trusted-types-for
  'script'; trusted-types sempere-pdf-worker`. No inline script or style, no
  `eval`, no WebAssembly, no third-party origin. `blob:` URLs are created by
  the page only, from verified blobs with a type the viewer sets (`image/jpeg`,
  `image/png`, PNGs it rendered itself, `audio/*`); the DOM builder refuses
  any other image reference. The one Trusted Types policy admits exactly the
  URL of the bundled pdf.js worker.
- **Attachments are untrusted too.** A blob is used only after it verified
  (above); a hostile writer who holds a vault key can still store a crafted
  image, PDF or audio file under a valid name. Those reach the browser's own
  decoders (images, audio) and pdf.js, never markup: images are checked and
  stripped first and shown through `<image>` (no script runs in an image),
  audio goes to `<audio>`, and a PDF is parsed by pdf.js in its worker with
  scripting, XFA, annotations, font loading (glyphs are drawn as paths) and
  WebAssembly off; it can only produce pixels. Reading a PDF, reading a
  page and drawing a page each stop after 30 s; a PDF that hangs while being
  read gets the worker replaced, so later notes are not blocked by it. Transcripts are JSON shown as text.
- **Bounded work** (§9): blobs within the limits of "Attachments" above,
  images within 100 MP before decoding, at most 10 000 items per page,
  revision files up to 256 MiB and 256 MiB after gunzip, `vault.json` 16 MiB, listings 16 MiB (PROPFIND) and 64 MiB (index),
  the unknown-field budget of §9 (24 levels, 16 384 values per file), and the
  renderer limits of `SempereRender` (extent 200 000 pt, samples per control
  point, outline points per page, ruling commands per band and page). Every
  failure is a typed error shown to the user; a seeded fuzz test checks that.
- **Names are validated** before use: note directories must be lowercase
  UUIDs and revision files canonical `<hlc>-<device>-<seq>.<kind>.age` names;
  anything else is ignored (§1), so a listing cannot point the viewer at
  another path.

**The key:** pasted into a text area, read once, and held only in the
`Decrypter` object in memory. It is not stored (no cookies, `localStorage`,
IndexedDB or service worker), not put in the URL, not logged, and never sent:
the only requests the viewer makes are `GET` and `PROPFIND` for vault files,
which carry no key material, and (when a note has a PDF page) `GET`s of the
viewer's own pdf.js files: the worker, standard fonts, CMaps and the
JavaScript JPEG 2000 / JBIG2 decoders under `pdfjs/`, which say only that some
PDF needed them. **Lock** reloads the page, which drops the key and
every decrypted note. JavaScript cannot guarantee that memory is wiped, and a
browser extension with access to the page can read anything the page can; use
a browser profile without such extensions for sensitive vaults.

**Metadata visible to the server** (as for any storage, `docs/io.md`): note
ids, revision file names (time, device id, sequence), blob names, kinds and
sizes, file sizes, and when the viewer reads which file (a blob is read when
its item comes on screen, audio when it is played, so the server can tell
roughly where a reader is in a note). `sempere-index.json` lists the same names; it
holds no content.

**Out of scope:** a compromised host serving modified viewer code, a
compromised browser or OS, shoulder surfing, and traffic analysis.

## Hosting

The viewer is static files: `web/dist/` after `npm run build` (relative
paths, so any sub-path works). The vault is any folder of its files. Put both
on **one origin** (for example `https://notes.example.org/` for the viewer and
`https://notes.example.org/vault/` for the vault): then `connect-src 'self'`
covers it and no CORS is needed. To read a vault on another origin, build with
it allowed, `SEMPERE_CONNECT_SRC="https://dav.example.org" npm run build`
(space-separated origins), and have that server send CORS headers for the
viewer's origin (`Access-Control-Allow-Origin`, and for WebDAV
`Access-Control-Allow-Methods: GET, PROPFIND`, `Access-Control-Allow-Headers:
Depth, Content-Type`, plus `Access-Control-Allow-Credentials: true` if it
needs a login).

`index.html?vault=https://notes.example.org/vault/` pre-fills the URL (never
put a key in a URL).

### A WebDAV mirror made by `sempere sync webdav`

The setup the roadmap plans: the vault lives in iCloud Drive; a Mac runs
`sempere sync webdav` every few minutes (`launchd`), mirroring it to a WebDAV
share on a home server; the server also serves the viewer. The viewer lists
the share with `PROPFIND` (`Depth: 1`) and reads files with `GET`, so the
share needs no index. Authentication is the web server's (HTTP Basic or a
login cookie, prompted by the browser); the viewer sends credentials only to
its own origin.

```bash
# on the Mac, from the iCloud vault (docs/cli.md "Sync")
SEMPERE_WEBDAV_PASSWORD=… sempere sync webdav https://notes.example.org/vault/ \
  --vault ~/Library/Mobile\ Documents/com~apple~CloudDocs/Notes.sempere --user notes
```

A Caddy site for viewer and share (Caddy's `webdav` module):

```caddyfile
notes.example.org {
	basic_auth {
		notes <bcrypt hash>
	}
	header {
		Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; media-src blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; worker-src 'self'; manifest-src 'none'; require-trusted-types-for 'script'; trusted-types sempere-pdf-worker"
		Referrer-Policy no-referrer
		X-Content-Type-Options nosniff
		Strict-Transport-Security "max-age=31536000"
	}
	handle_path /vault/* {
		root * /srv/sempere/Notes.sempere
		webdav
	}
	handle {
		root * /srv/sempere/viewer
		file_server
	}
}
```

Send the CSP as a header as well as the built-in meta tag: only the header can
carry `frame-ancestors` (no framing of the viewer), and only a header applies
to the pdf.js worker. Serve `.mjs` files as `text/javascript` (Caddy does): the
worker is a module.

### A plain static server

A static server (nginx, GitHub Pages, S3, `python3 -m http.server`) cannot
list folders, so the vault needs a listing next to `vault.json`:

```bash
sempere vault index --vault /srv/www/Notes.sempere     # writes Notes.sempere/sempere-index.json
```

`sempere-index.json` is `{"format": "sempere-index/1", "notes":
{"<noteId>": ["<revision file>", …]}}`: note ids and revision names only,
which the server sees anyway. It needs no key. Once it exists it stays
current with no manual step: every `sempere` command that opens the vault
(`compact`, `import`, `snapshot`, edits, `sync webdav`, even `verify`)
rewrites it when the vault's listing changed since, and `sync webdav`
rewrites the server's copy, if the server has one, to list what the server
holds after the sync. No command creates it except `vault index`. A copy made
by other means (`rsync` of the vault folder) carries the index with it. Writes
by the app do not update it; the next `sempere` command does. Every reader
treats the file as an unknown file and ignores it (`format.md` §1); `sync
webdav` never copies it from one side to the other. `--out -` prints it, `--out PATH`
writes it elsewhere. The viewer's listing choice "Index file or WebDAV" tries
the index first and falls back to `PROPFIND`.

### Local folders

"Open a vault folder…" uses `showDirectoryPicker` (read-only) where the
browser has it, and a folder `<input>` elsewhere; dropping the `.sempere`
folder works in every current browser. In Safari and Firefox the folder input
reads every file of the folder into a list first; very large vaults open
faster from a URL. Files in iCloud Drive that are not downloaded to the
computer (`.icloud` placeholders) are not part of the folder and their notes
are missing: download the vault first.

## Limits

- **Read-only.** No editing, no restore, no history browser, no export.
- **Attachments**: text boxes use the browser's fonts, so glyph widths differ
  from the app's and the CLI's (lines and heights do not when `breaks` are
  stored); underline and strikethrough are the browser's, not at the format's
  offsets; a renderer without a font for a script shows the browser's
  fallback, not a report. HEIC images are placeholders. PDF pages need a
  browser with module workers (every current one); the pdf.js build used is
  the "legacy" one, which polyfills recent JavaScript for older browsers.
  Blobs are held in memory while their note is open (no temporary files in a
  browser). Transcripts are not searched (the CLI's `search --transcripts`
  is), and ink is not linked to audio (`rec`) yet.
- **Ink** is drawn like `SempereRender`: flat colour per stroke (mean opacity
  times a tool factor), no pencil grain, watercolour bleed or nib angle; the
  same approximations as the CLI's PDF and SVG exports.
- **Legacy vaults** (any X25519 recipient) are refused: migrate first.
- **Passphrase-wrapped keys** (`keys/*.key.age`) are not offered: paste the
  key itself. (Typage can decrypt scrypt files; supporting it means scrypt
  with work factor up to 2^20, 1 GiB, in the browser.)
- **Everything is decrypted on open**, to list titles and tags: a vault of a
  few hundred notes takes seconds (four notes and up to 24 requests at a
  time). Summaries are not cached between visits (the `format.md` §10 cache
  is per device and would need storage), and the decrypted notes are kept
  only for the notes opened most recently.
- **Search** covers titles, tags, notebooks, recognised text, text boxes and
  PDF page text (`pageText`, format.md §8.2.6), as in the app; words are not
  highlighted on the page yet. A note with `markersBehindText` (§5.4) draws
  its marker strokes below its text boxes and images (§8.2.3), as the CLI's
  exports do.
- Integers in revisions are read up to ±2^53 (every value the format defines
  is below that); Swift accepts larger ones for a few informational fields and
  for origin indices.

## Development and tests

```bash
cd web
npm ci                 # exact versions from package-lock.json
npm run dev            # Vite dev server (no CSP in dev mode)
npm run lint && npm run typecheck && npm test
npm run build          # dist/, with the CSP meta tag
npm run fixture        # rewrite test/fixtures/render.sempere (TypeScript writes, Swift reads)
scripts/golden.sh      # rewrite test/golden from the Swift CLI (builds it)
# browser smoke tests, Playwright + Chromium (smoke.mjs needs sempere-index.json in the vault: `sempere vault index`):
node scripts/smoke.mjs ../Tests/SempereTests/Fixtures/sample.sempere ../Tests/SempereTests/Fixtures/sample.key
node scripts/smoke-attachments.mjs test/fixtures/render.sempere ../Tests/SempereTests/Fixtures/sample.key
```

Tests (`web/test/`, vitest, Node 22):

- **Cross-check with the Swift CLI** (`crosscheck.test.ts`): for every note of
  `Tests/SempereTests/Fixtures/sample.sempere` and of
  `web/test/fixtures/render.sempere`, the TypeScript reconstruction must equal
  `sempere export --format json` and the TypeScript SVG must equal
  `sempere export --format svg` byte for byte. The render fixture is written
  by `scripts/make-fixture.ts` (encrypted to the throwaway test key) and covers
  every paper kind, every tool, transforms, dots, infinite pages, two devices
  with a snapshot, removals, page order, recognition, legacy and per-tag
  tags, an orphan delta, attachments and unknown fields. CI's `web-golden`
  job regenerates `test/golden` with the CLI (SVG with `--pdf-renderer none`,
  so PDF pages are placeholders there and the goldens do not depend on a
  Poppler version) and fails on any difference, so the committed goldens are
  always the Swift output.
- **Attachments against the CLI** (`items-crosscheck.test.ts`): two fixture
  notes with blobs (`test/fixtures/media/`: a synthetic JPEG with EXIF and a
  comment, a PNG with a text chunk, a hand-written two-page PDF with a
  CropBox and `/Rotate`, a one-second tone, a transcript; plus a missing, a
  forged and a HEIC blob, unknown and reserved kinds). The page outside the
  `items` group is compared byte for byte; the group itself structurally,
  since the CLI embeds its own font subsets: background fills, placeholders,
  each image's clip polygon and matrix (blobs read by the viewer's own
  reader), each text line's baseline, size, characters, direction (and x
  where it does not depend on glyph widths), and each text box's rotation.
- Blobs (`blobs.test.ts`: the §8.1.3 test vector, Padmé, every framing
  failure, missing, forged and cross-note blobs, the previous secret during a
  rewrap), images, placement, text layout and transcripts
  (`attachment-render.test.ts`), and pdf.js's effective page and crop mapping
  for each `/Rotate` (`pdf.test.ts`, rendered in Node with pdf.js's optional
  `@napi-rs/canvas`).
- Ports of the Swift merge, tag, clock, model, search and notebook tests,
  including §5.3's shuffled-order reconstruction and the multi-device tag
  convergence simulation.
- Vault and source tests: legacy refusal, wrong key, tag binding to note and
  file name, unreadable revisions reported, bounded reads and gunzip, index
  and PROPFIND parsing with hostile names.
- A seeded fuzz test of the decoders, the merge, the renderer, item layout,
  image headers, transcripts, blob framing and the listing parsers (typed
  errors only).

CI (`.github/workflows/ci.yml`): the `changes` job runs the `web` job (lint,
typecheck, tests, build) only when `web/` (or the workflow) changes, and the
`web-golden` job (Swift CLI goldens) also when the Swift code that writes them
changes (`Sources/` of the reducer, renderer and CLI, the fixture vault,
`Package.*`): a PR that moves the CLI's export must update `web/` with it.
`main` runs both always.

Dependencies are pinned exactly in `web/package.json` and
`web/package-lock.json`. Runtime: `age-encryption` (typage, BSD-3-Clause) with
its `@noble`/`@scure` libraries (MIT; `@noble/hashes` is also used directly,
for the streaming SHA-256 of blobs), and `pdfjs-dist` 6.4.299 (Apache-2.0;
its standard fonts are under the Foxit and Liberation (OFL) licences, copied
with them into `dist/pdfjs/`). pdf.js is loaded only when a note shows a PDF
page; its build-time copy step is the `sempere-pdfjs-assets` plugin in
`vite.config.ts`. Install
with `npm ci`, never `npm install`, in CI and for releases.
