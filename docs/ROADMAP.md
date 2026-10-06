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
| Vault | Fast summaries (no stroke points, parallel) and per-device encrypted summary cache (`format.md` §10) | ✅ #54 |
| Vault | Fast exact decoding of stroke points; per-device cache keys (`format.md` §10.1) | 🔀 #56 |
| Vault | Tags merge per tag (add wins) | 🔀 #23 |
| Vault | Hardened parsers + fuzz harness (untrusted input) | 🔀 #25 |
| Vault | Attachment model types and ops (A0) | ✅ |
| Vault | Per-note blob store, rewrap policy, GC, repair (B2) | ✅ |
| Vault | Attachment merge (A1) | 📋 |
| Vault | Read-only access to newer format versions | 💭 |
| Render | PDF, SVG, PNG export of ink and paper | ✅ |
| Render | Parametric paper templates (line width, spacing) | 🔀 #28 |
| Render | PDF page backgrounds in exports (Form XObjects in PDF, rasterizer in SVG/PNG, placeholders, export report) and the `SemperePDF` reader (C3) | ✅ |
| Render | Images in exports: JPEG passthrough, PNG/JPEG decoders, SVG data URIs or `--assets`, placeholders (C1) | 🔀 #62 |
| Render | Unicode text in exports: bundled Noto + font packs, UAX #9/#14/#29, shaper, font subsets in PDF/SVG, missing-script report (C2) | 🔀 #64 |
| Render | Recordings in exports (C4) | 📋 |
| Import | Notability `.note` / `.ntb` / full Google Drive backup, recognised text | ✅ |
| Import | Notability PDF backgrounds, images, typed text, recordings (D1–D4) | 📋 |
| Sync | WebDAV | ✅ |
| Sync | WebDAV for attachments (B3) | 📋 |

## CLI (`sempere`; one codebase for both platforms)

The CLI gets every feature first, or at the latest with the app (`CLAUDE.md`
"CLI first"): anything that reads or changes vault data has a command with
`--json`.

| Feature | Linux | macOS |
| --- | --- | --- |
| keys, vault init/info/recipients/verify, notes, history/restore, compact, snapshot | ✅ | ✅ |
| import notability, search (recognised text) | ✅ | ✅ |
| Note editing as in the app: `notes new/rename/tag/move/paper/delete/undelete`, `notebooks list/rename` (subtree), `tags list`, `pages list/add`, `notes list --notebook` over sub-notebooks | 🔀 this PR | 🔀 this PR |
| Pages: delete, move/reorder, duplicate; paged/pageless (`notes layout` in #52) | 📋 after #52 | 📋 after #52 |
| `recognize` (Vision on rendered pages) and `import notability --recognize missing`; Linux gives a clear error | — (error) | 📋 after #44 |
| Fast `notes list` / `search` (parallel, summary cache in `~/.cache/sempere`) | 🔀 #54 | 🔀 #54 |
| export PDF / SVG / PNG | ✅ | ✅ |
| sync webdav | ✅ | ✅ |
| Recovery kit (paper key), backup / verify / restore | 🔀 #30 | 🔀 #30 |
| Markdown (Obsidian) and single-file HTML export | 🔀 #27 | 🔀 #27 |
| Release builds: static binary (Linux x86_64 + aarch64), universal (macOS), Homebrew formula, provenance | 🔀 #26 | 🔀 #26 |
| Attachments: `blobs` (list, verify, extract, add, copy, unused, gc, repair), `recipients --rewrap`, `recover` of a blob (B2) | 🔀 #60 | 🔀 #60 |
| Attachments: `import pdf`, `attach`, `notes show`, search over text and transcripts (F) | 📋 | 📋 |
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
| Canvas | Pages vs pageless (reorder, delete pages) | 📋 round 2 |
| Canvas | Remote changes merged into an open note | 📋 round 2 |
| Search | Handwriting search: Vision on rendered pages writes page recognition (`format.md` §5.5), search over text, title, notebook, tag, jump to the page | ✅ (not yet tried on the iPad; no word highlight on the page yet) |
| App | Share/export from the app: PDF, PNG pages, Text (Markdown, PDF optional), one note or a multi-selection, share sheet + Save to Files, progress and cancel (`ShareExport`, `ExportJob`; Catalyst menu bar via `ExportMenuCommands`); HTML in the CLI only | ✅ #42, text export 🔀 #56 |
| App | History browser: restore points, read-only preview, restore through `NoteWriter`, compaction notice | 🔀 #41 |
| App | Settings panel (E6) | 📋 |
| App | Spanish localization (L) | 📋 |
| Attachments | Images, text boxes, PDF import, audio recording + playback, on-device transcription, unused-attachment index (E0–E5, E7) | 📋 |
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
| Web viewer with in-browser decryption | 🔀 #63 | `web/` (TypeScript, Vite, no backend; `docs/web-viewer.md`): opens a vault from a static or WebDAV URL or a local folder, decrypts with typage (MLKEM768-X25519) in the page, merges and draws notes exactly as the CLI's JSON and SVG exports (cross-checked in CI), notebooks, tags, search, pan and zoom. Key pasted, memory only; strict CSP. Later: attachments (with A1), passphrase-wrapped keys, a passkey. Hosted in the maintainer's home lab behind the existing Caddy/TLS. |
| WebDAV mirror for the viewer | 📋 with the web viewer (#63 documents the Caddy + `sync webdav` setup; static hosts use `sempere vault index`) | A WebDAV share on the NAS, plus a macOS `launchd` agent running `sempere sync webdav` every few minutes from the iCloud vault. The CLI already does the sync; the setup lives in the sysadmin repo. Decided 2026-10-06: wait until the viewer exists. |
| WebDAV as a vault location in the app | 💭 low priority | Only for users with no Mac and no iCloud. iPadOS cannot sync in the background, so for mirroring the CLI job is better. It would wrap the same `SempereWebDAV` library. |
| Other Files-app providers (Google Drive, Proton Drive, Dropbox, OneDrive, Nextcloud) | 💭 test on demand | They probably already work through the folder picker. The download checks are tuned for iCloud, so each provider needs a test pass. |
