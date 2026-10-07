# Roadmap

Where every feature sits, by component. Status: ✅ done on `main` · 🔀 open PR ·
📋 planned (next) · 💭 future. Task ids (A0, E2, …) are in `docs/plan.md`, with
details in `docs/attachments.md` §14. `docs/HANDOFF.md` has the current
working state.

## Order of work

| Step | What | Blocks |
| --- | --- | --- |
| 1 | Merge the reviewed batch: #25 → #23 → #33, #24 → #28, #30 → #27 → #26 | everything below |
| 2 | Rename sweep to Sempere (one PR; touches every file) | new feature branches; start them after this to avoid conflicts |
| 3 | Rebuild the test vault (post-quantum key, full import) → first TestFlight | device testing |
| 4 | iPad round 2 and attachments A0 (in parallel) | the rest of attachments |
| 5 | Attachments, batches of 3–4 cloud sessions along the §14 dependencies | math, video |
| 6 | Mac polish → App Store submission (iPad + Mac) → `/ultrareview` | public release |

## Shared library (`Sources/`: Age, Sempere, SempereRender, SempereImport, SempereWebDAV)

| Area | Feature | Status |
| --- | --- | --- |
| Crypto | age v1: X25519, scrypt, armor, STREAM; CCTV vectors | ✅ |
| Crypto | Post-quantum ML-KEM-768 + X25519 recipients; vaults post-quantum only, legacy vaults open only to migrate | 🔀 #33 |
| Crypto | Streaming encrypt/decrypt, header-only rewrap, streaming re-encrypt (B1) | 🔀 #43 |
| Vault | Write-once revisions, HLC, merge, snapshots, compaction | ✅ |
| Vault | History and restore points | ✅ |
| Vault | Version history round 2 (`format.md` §5.8): checkpoints, editing-session ids, positioned snapshots (`asOf`), thinning with stated and property-tested guarantees; compaction keeps checkpoints complete | 🔀 #74 |
| Vault | Fast summaries (no stroke points, parallel) and per-device encrypted summary cache (`format.md` §10) | ✅ #54 |
| Vault | Fast exact decoding of stroke points; per-device cache keys (`format.md` §10.1) | 🔀 #56 |
| Vault | Tags merge per tag (add wins) | 🔀 #23 |
| Vault | Hardened parsers + fuzz harness (untrusted input) | 🔀 #25 |
| Vault | Attachment model types and ops (A0) | ✅ |
| Vault | Per-note blob store, rewrap policy, GC, repair (B2) | ✅ |
| Vault | Attachment merge (A1): items and recordings in merge, snapshots, history/restore, summaries | 🔀 #66 |
| Vault | Read-only access to newer format versions | 💭 |
| Render | PDF, SVG, PNG export of ink and paper | ✅ |
| Render | Pageless pages cut at gaps in the ink; paged notes one PDF page per page (`format.md` §5.4.3) | 🔀 #52 |
| Render | Parametric paper templates (line width, spacing) | 🔀 #28 |
| Render | PDF page backgrounds in exports (Form XObjects in PDF, rasterizer in SVG/PNG, placeholders, export report) and the `SemperePDF` reader (C3) | ✅ |
| Render | Images in exports: JPEG passthrough, PNG/JPEG decoders, SVG data URIs or `--assets`, placeholders (C1) | 🔀 #62 |
| Render | Unicode text in exports: bundled Noto + font packs, UAX #9/#14/#29, shaper, font subsets in PDF/SVG, missing-script report (C2) | 🔀 #64 |
| Render | Recordings in exports (C4) | 📋 |
| Import | Notability `.note` / `.ntb` / full Google Drive backup, recognised text | ✅ |
| Import | Notability PDF backgrounds and images (D1, D2) | 🔀 #70 |
| Import | Notability typed text, recordings and stroke links (D3, D4) | 🔀 #73 |
| Sync | WebDAV | ✅ |
| Sync | WebDAV for attachments (B3): streamed, resumable, GC-safe deletes | 🔀 #67 |

## CLI (`sempere`; one codebase for both platforms)

The CLI gets every feature first, or at the latest with the app (`CLAUDE.md`
"CLI first"): anything that reads or changes vault data has a command with
`--json`.

| Feature | Linux | macOS |
| --- | --- | --- |
| keys, vault init/info/recipients/verify, notes, history/restore, compact, snapshot | ✅ | ✅ |
| `notes layout paged\|pageless`, `export --breaks gaps\|fixed` | ✅ #52 | ✅ #52 |
| import notability, search (recognised text) | ✅ | ✅ |
| `notes checkpoint [--name]`, `notes history --sessions` (checkpoints and editing sessions, `--json`), `compact --thin-older-than 30d [--dry-run]` | 🔀 #74 | 🔀 #74 |
| import notability: PDF backgrounds and images, `--no-attachments`, `--keep-image-metadata` (D1, D2) | 🔀 #70 | 🔀 #70 |
| import notability: typed text and recordings (D3, D4) | 🔀 #73 | 🔀 #73 |
| Note editing as in the app: `notes new/rename/tag/move/paper/delete/undelete`, `notebooks list/rename` (subtree), `tags list`, `pages list/add`, `notes list --notebook` over sub-notebooks | ✅ #58 | ✅ #58 |
| Pages: `pages add --after`, `move`, `delete`, `duplicate`; paged/pageless (`notes layout`) | ✅ #52 | ✅ #52 |
| Items: `items list`, `move`, `rotate`, `front`, `delete`, `duplicate`, `copy` (the app's item gestures) | 🔀 #68 | 🔀 #68 |
| `recognize` (Vision on rendered pages, the app's selection, image plan and mapping) and `import notability --recognize missing`; Linux gives a clear error (`--dry-run` works) | — (error) | ✅ #78 |
| `notes search`: the app's ranked search over titles, tags, notebooks and recognised text | ✅ #78 | ✅ #78 |
| Fast `notes list` / `search` (parallel, summary cache in `~/.cache/sempere`) | 🔀 #54 | 🔀 #54 |
| export PDF / SVG / PNG | ✅ | ✅ |
| sync webdav | ✅ | ✅ |
| sync webdav of attachment blobs (`--max-blob-mib`) | 🔀 #67 | 🔀 #67 |
| Recovery kit (paper key), backup / verify / restore | 🔀 #30 | 🔀 #30 |
| Markdown (Obsidian) and single-file HTML export | 🔀 #27 | 🔀 #27 |
| Release builds: static binary (Linux x86_64 + aarch64), universal (macOS), Homebrew formula, provenance | 🔀 #26 | 🔀 #26 |
| Attachments: `blobs` (list, verify, extract, add, copy, unused, gc, repair), `recipients --rewrap`, `recover` of a blob (B2) | 🔀 #60 | 🔀 #60 |
| Attachments: `notes show` lists items and recordings, `notes list --json` counts them, `search` finds typed text (A1) | 🔀 #66 | 🔀 #66 |
| Attachments: `attach image\|pdf\|text\|recording\|transcript`, `import pdf`, `search` over text boxes and (`--transcripts`) transcripts, typed text in Markdown/HTML exports (F) | 🔀 #69 | 🔀 #69 |
| PDF backgrounds in export (PDF exact; SVG/PNG via Poppler if installed, `--pdf-renderer`) | 🔀 #61 | 🔀 #61 (Poppler too; the app uses PDFKit) |
| Math, video in exports | 💭 | 💭 |

## iPad app (`Apps/`, SwiftUI + PencilKit, iPadOS 26)

| Area | Feature | Status |
| --- | --- | --- |
| Vaults | Open/create vaults, recents, iCloud Drive (dataless files handled), always-on sync loop with progress | ✅ |
| Vaults | Keys in the Keychain / password manager | 🔀 #24 |
| Vaults | Fast opening: background listing with "Opening vault: n of m", list fills in as notes are read, encrypted summary cache for instant reopen, empty list always explained | ✅ #54 |
| Vaults | Instant reopen from the local index; change-driven iCloud updates (names diff, file presenter), low-priority validation, throttled diff list updates; signposts + debug timing log | 🔀 #56 |
| Canvas | Fast note open: encrypted per-page drawing cache (LRU, 200 MB), off-main visible-first conversion, fast point decoding | 🔀 #56 |
| Notes | Notebook tree, tags (with tag UI), rename, move, delete/restore, duplicate titles allowed | ✅ (title rename 🔀 #24) |
| Canvas | PencilKit drawing, tool palette (full / compact), scrolling past the end, Keep Screen On | ✅ |
| Canvas | Object eraser by default, eraser sizes and cursor | 🔀 #24 |
| Canvas | Visual paper picker (line width, spacing) | 🔀 #28 |
| Canvas | Pages vs pageless (switch without moving ink; add after current / at end, delete with undo, duplicate, drag to reorder in a thumbnail strip) | 🔀 #52 |
| Canvas | Remote changes merged into an open note | 📋 round 2 |
| Search | Handwriting search: Vision on rendered pages writes page recognition (`format.md` §5.5), search over text, title, notebook, tag, jump to the page | ✅ (not yet tried on the iPad; no word highlight on the page yet) |
| App | Share/export from the app: PDF, PNG pages, Text (Markdown, PDF optional), one note or a multi-selection, share sheet + Save to Files, progress and cancel (`ShareExport`, `ExportJob`; Catalyst menu bar via `ExportMenuCommands`); HTML in the CLI only | ✅ #42, text export 🔀 #56 |
| App | History browser: restore points, read-only preview, restore through `NoteWriter`, compaction notice | 🔀 #41 |
| App | Version history round 2: Save Version (note toolbar, Mac Note menu ⌥⌘S), history grouped into checkpoints and collapsed editing sessions, thinning setting (default 30 days, or never) in a minimal Settings sheet with "Thin Now" preview, automatic thinning once a day | 🔀 #74 (not yet tried on the iPad) |
| App | Settings panel (E6) | 📋 (a minimal Settings sheet with the version-history setting exists, #74) |
| App | Spanish localization (L) | 📋 |
| Attachments | Plumbing (E0): items drawn between paper and ink (placeholders for missing blobs), select/move/resize/delete/duplicate/copy-paste with undo, blob cache, lazy per-kind iCloud download | 🔀 #68 |
| Attachments | Images (E1) and PDF import with tiled backgrounds (E3) | 🚧 in progress |
| Attachments | Text boxes, audio recording + playback, on-device transcription, unused-attachment index (E2, E4, E5, E7) | 📋 |
| Future | Math (LaTeX typing, handwriting → LaTeX on device; G1) | 💭 after E2 + C3 |
| Future | Video attachments (G2) | 💭 after E4 |
| Release | TestFlight, then App Store | 📋 after the rename |
| Release | App Store screenshots generated from a synthetic demo vault (`scripts/screenshots.sh`, CI dispatch) | 🔀 #53 |

## macOS app (the iPad app via Mac Catalyst; same target, same code)

The gap to the iPad is small for features and moderate for polish. Every
iPad feature above is in the Mac build automatically, because it is the same
target, and CI compiles it on every PR. What is missing is Mac-specific
behaviour and testing on a real Mac.

| Feature | Status |
| --- | --- |
| Builds and launches under Catalyst (CI `app` job) | ✅ |
| Everything in the iPad table | same status as the iPad |
| Tested by hand on a Mac (vault open, iCloud, Keychain) | 📋 |
| Saved folder access in a sandboxed Mac build | 🔀 access check, entitlements and a DEBUG probe done; the plain bookmark under the sandbox is unverified until a signed build is tried (`docs/io.md`) |
| Menus and keyboard shortcuts | 🔀 `docs/mac.md` |
| Export menu (File ▸ Export) | 🔀 #42 (`ExportMenuCommands`) |
| Multiple windows (one note per window), state restoration | 🔀 `docs/mac.md` |
| Drag a note to the Finder as PDF | 🔀 `docs/mac.md` |
| Bulk export from the app | 📋 with the share/export work (the CLI has it) |
| Key management window (recipients, add/remove device key, paper kit) | 🔀 `docs/mac.md` |
| Drawing with mouse/trackpad (any input, object eraser takes the pointer, tool-sized cursor, ruler) | 🔀 `docs/mac.md`; mouse stroke smoothing 💭 |
| Mac App Store build (same bundle, universal purchase) | 📋 with the App Store submission |
| Mac App Store screenshots (Catalyst, 2880 × 1800, best effort) | 🔀 #53 |

## Future: iPhone and web

| Feature | Status | Notes |
| --- | --- | --- |
| iPhone app as a reader | 🔀 #65 (`docs/iphone.md`) | Same SwiftUI target, device family 1,2. Compact stack (vault, notebooks and tags, list, note); read-first note view (pan, zoom, page bar, finger annotation behind a pencil button); search, export, history and Face ID unlock shared with the iPad; tests at iPhone sizes run on an iPhone simulator in the `app` job; 6.9" screenshots (`scripts/screenshots.sh iphone`). Not yet tried on a physical iPhone. |
| Web viewer with in-browser decryption | ✅ #63; attachments 🔀 #75 | `web/` (TypeScript, Vite, no backend; `docs/web-viewer.md`): opens a vault from a static or WebDAV URL or a local folder, decrypts with typage (MLKEM768-X25519) in the page, merges and draws notes exactly as the CLI's JSON and SVG exports (cross-checked in CI), notebooks, tags, search, pan and zoom. Key pasted, memory only; strict CSP. Attachments (#75): images, text boxes (stored `breaks`), PDF pages (pinned pdf.js), placeholders, recordings with playback and transcripts; blobs fetched lazily and verified (hash and keyed name). Later: transcript search, passphrase-wrapped keys, a passkey. Hosted in the maintainer's home lab behind the existing Caddy/TLS. |
| WebDAV mirror for the viewer | 📋 with the web viewer (#63 documents the Caddy + `sync webdav` setup; static hosts use `sempere vault index`) | A WebDAV share on the NAS, plus a macOS `launchd` agent running `sempere sync webdav` every few minutes from the iCloud vault. The CLI already does the sync; the setup lives in the sysadmin repo. Decided 2026-10-06: wait until the viewer exists. |
| WebDAV as a vault location in the app | 💭 low priority | Only for users with no Mac and no iCloud. iPadOS cannot sync in the background, so for mirroring the CLI job is better. It would wrap the same `SempereWebDAV` library. |
| Other Files-app providers (Google Drive, Proton Drive, Dropbox, OneDrive, Nextcloud) | 💭 test on demand | They probably already work through the folder picker. The download checks are tuned for iCloud, so each provider needs a test pass. |
