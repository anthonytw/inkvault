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
| Vault | Tags merge per tag (add wins) | 🔀 #23 |
| Vault | Hardened parsers + fuzz harness (untrusted input) | 🔀 #25 |
| Vault | Attachment model + merge (A0, A1); per-note blob store, rewrap policy, GC (B2) | 📋 |
| Vault | Read-only access to newer format versions | 💭 |
| Render | PDF, SVG, PNG export of ink and paper | ✅ |
| Render | Parametric paper templates (line width, spacing) | 🔀 #28 |
| Render | Images, Unicode text, PDF backgrounds, recordings in exports (C1–C4) | 📋 |
| Import | Notability `.note` / `.ntb` / full Google Drive backup, recognised text | ✅ |
| Import | Notability PDF backgrounds, images, typed text, recordings (D1–D4) | 📋 |
| Sync | WebDAV | ✅ |
| Sync | WebDAV for attachments (B3) | 📋 |

## CLI (`sempere`, renamed `sempere`; one codebase for both platforms)

| Feature | Linux | macOS |
| --- | --- | --- |
| keys, vault init/info/recipients/verify, notes, history/restore, compact, snapshot | ✅ | ✅ |
| import notability, search (recognised text) | ✅ | ✅ |
| export PDF / SVG / PNG | ✅ | ✅ |
| sync webdav | ✅ | ✅ |
| Recovery kit (paper key), backup / verify / restore | 🔀 #30 | 🔀 #30 |
| Markdown (Obsidian) and single-file HTML export | 🔀 #27 | 🔀 #27 |
| Release builds: static binary (Linux x86_64 + aarch64), universal (macOS), Homebrew formula, provenance | 🔀 #26 | 🔀 #26 |
| Attachments: `blobs`, `import pdf`, `attach`, `notes show`, search over text and transcripts (F) | 📋 | 📋 |
| PDF backgrounds in SVG/PNG export | 📋 via Poppler if installed | 📋 via PDFKit |
| Math, video in exports | 💭 | 💭 |

## iPad app (`Apps/`, SwiftUI + PencilKit, iPadOS 26)

| Area | Feature | Status |
| --- | --- | --- |
| Vaults | Open/create vaults, recents, iCloud Drive (dataless files handled), always-on sync loop with progress | ✅ |
| Vaults | Keys in the Keychain / password manager | 🔀 #24 |
| Notes | Notebook tree, tags (with tag UI), rename, move, delete/restore, duplicate titles allowed | ✅ (title rename 🔀 #24) |
| Canvas | PencilKit drawing, tool palette (full / compact), scrolling past the end, Keep Screen On | ✅ |
| Canvas | Object eraser by default, eraser sizes and cursor | 🔀 #24 |
| Canvas | Visual paper picker (line width, spacing) | 🔀 #28 |
| Canvas | Pages vs pageless (reorder, delete pages) | 📋 round 2 |
| Canvas | Remote changes merged into an open note | 📋 round 2 |
| Search | Handwriting search (Vision on rendered pages) | 📋 round 2 |
| App | Share/export (PDF, Markdown) from the app | 📋 round 2 |
| App | History browser (restore points) | 📋 round 2 |
| App | Settings panel (E6) | 📋 |
| App | Spanish localization (L) | 📋 |
| Attachments | Images, text boxes, PDF import, audio recording + playback, on-device transcription, unused-attachment index (E0–E5, E7) | 📋 |
| Future | Math (LaTeX typing, handwriting → LaTeX on device; G1) | 💭 after E2 + C3 |
| Future | Video attachments (G2) | 💭 after E4 |
| Release | TestFlight, then App Store | 📋 after the rename |

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
| Saved folder access in a sandboxed Mac build (bookmarks untested) | 📋 |
| Menus and keyboard shortcuts | 📋 Phase 2 |
| Multiple windows (one note per window) | 📋 Phase 2 |
| Drag-and-drop export, bulk export | 📋 Phase 2 |
| Key management window | 📋 Phase 2 |
| Drawing with mouse/trackpad (PencilKit works; tuning for no pencil) | 📋 Phase 2 |
| Mac App Store build (same bundle, universal purchase) | 📋 with the App Store submission |
