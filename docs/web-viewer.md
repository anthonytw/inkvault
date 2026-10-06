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

## How it reads a vault

The code mirrors the Swift reader and is tested against it (see "Tests").

| Step | Where | Swift counterpart |
| --- | --- | --- |
| `vault.json`: format, recipients, legacy check | `web/src/vault/vault.ts` | `Vault.readManifest` |
| age decryption (MLKEM768-X25519 stanzas) | [typage](https://github.com/FiloSottile/typage) `age-encryption` 0.3.1 | `Age` |
| `SMPR` framing, HMAC-SHA256 tag under the vault secret (WebCrypto), previous secret during a rewrap | `vault.ts` | `BodyFraming`, `NoteStore.unframe` |
| bounded gunzip (`DecompressionStream`), strict UTF-8, JSON | `web/src/vault/gzip.ts` | `Gzip.decompress` |
| revision decoding with Swift's `Codable` rules; name and content must agree (§5) | `web/src/format/model.ts`, `ids.ts`, `rfc3339.ts`, `attachments.ts` | `Model.swift`, `Revision.swift`, `Attachments.swift` |
| merge: snapshots, uncovered deltas, LWW registers, tombstones, orphans, tag OR-set with legacy baseline | `web/src/format/reducer.ts`, `tags.ts` | `NoteReducer` |
| B-spline sampling, ribbons, monoline, paper ruling, page extent | `web/src/render/` | `SempereRender` |

Typage 0.3.1 implements the age v1.3 hybrid recipient (`mlkem768x25519`,
HPKE with X-Wing) with `@noble/post-quantum`; the viewer has no cryptography
of its own beyond calling typage and WebCrypto (HMAC-SHA256).

Unreadable revisions (wrong tag, undecryptable, undecodable) are reported in
the note view and the list ("N unreadable revisions", a "Problems" filter);
the note is shown merged from the rest, marked as such (§4: report, never
silently drop). Notes holding attachments (§8) say that text boxes, images,
PDFs and recordings are not shown yet: like the Swift reducer (task A1), the
viewer validates them but does not merge or draw them.

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
  img-src 'self' data:; connect-src 'self' [vault origins]; base-uri 'none';
  form-action 'none'; object-src 'none'; frame-src 'none'; worker-src 'none';
  manifest-src 'none'; require-trusted-types-for 'script'; trusted-types 'none'`.
  No inline script or style, no `eval`, no third-party origin.
- **Bounded work** (§9): revision files up to 256 MiB and 256 MiB after
  gunzip, `vault.json` 16 MiB, listings 16 MiB (PROPFIND) and 64 MiB (index),
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
which carry no key material. **Lock** reloads the page, which drops the key and
every decrypted note. JavaScript cannot guarantee that memory is wiped, and a
browser extension with access to the page can read anything the page can; use
a browser profile without such extensions for sensitive vaults.

**Metadata visible to the server** (as for any storage, `docs/io.md`): note
ids, revision file names (time, device id, sequence), file sizes, and when
the viewer reads which file. `sempere-index.json` lists the same names; it
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
		Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; worker-src 'none'; manifest-src 'none'; require-trusted-types-for 'script'; trusted-types 'none'"
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
carry `frame-ancestors` (no framing of the viewer).

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
- **Attachments** (§8) are not merged or drawn yet (as in the Swift library,
  task A1); notes holding them say so.
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
- **Search** covers titles, tags, notebooks and recognised text, as in the
  app; words are not highlighted on the page yet.
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
# browser smoke test, Playwright + Chromium:
node scripts/smoke.mjs ../Tests/SempereTests/Fixtures/sample.sempere ../Tests/SempereTests/Fixtures/sample.key
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
  job regenerates `test/golden` with the CLI and fails on any difference, so
  the committed goldens are always the Swift output.
- Ports of the Swift merge, tag, clock, model, search and notebook tests,
  including §5.3's shuffled-order reconstruction and the multi-device tag
  convergence simulation.
- Vault and source tests: legacy refusal, wrong key, tag binding to note and
  file name, unreadable revisions reported, bounded reads and gunzip, index
  and PROPFIND parsing with hostile names.
- A seeded fuzz test of the decoders, the merge, the renderer and the
  listing parsers (typed errors only).

CI (`.github/workflows/ci.yml`): the `changes` job runs the `web` job (lint,
typecheck, tests, build) only when `web/` (or the workflow) changes, and the
`web-golden` job (Swift CLI goldens) also when the Swift code that writes them
changes (`Sources/` of the reducer, renderer and CLI, the fixture vault,
`Package.*`): a PR that moves the CLI's export must update `web/` with it.
`main` runs both always.

Dependencies are pinned exactly in `web/package.json` and
`web/package-lock.json`; the only runtime dependency is `age-encryption`
(typage, BSD-3-Clause) with its `@noble`/`@scure` libraries (MIT). Install
with `npm ci`, never `npm install`, in CI and for releases.
