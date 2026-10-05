# InkVault design

Decisions made 2026-10-04. `docs/format.md` is the normative on-disk spec;
this document records *why*.

## Goals

1. Handwriting on iPad that feels native. A Mac companion for browsing,
   searching, exporting and light annotation.
2. End-to-end encryption with keys the user owns outright: generate anywhere,
   import by AirDrop, QR or paste, export at any time, encrypt to several keys.
   A dead device must cost nothing.
3. Sync through any storage the user already has, with no server of ours.
4. Notes readable and exportable (PDF, SVG) without the app, from a backup.
5. Small feature set: a few pens, a few papers, notebooks and tags, search,
   and attachments on pages: typed text boxes, images, PDF page backgrounds,
   audio recordings (`docs/attachments.md`). No AI services: handwriting
   recognition and transcription run on device only, opt-in, and any future
   smart feature (handwriting to LaTeX, say) will be on-device AI only. No
   accounts, no telemetry, no subscriptions.

## Non-goals (for now)

Collaboration between people, real-time sync, Android, Windows, typed text
documents (reflowing text with ink anchored to it; text boxes placed on a page
are in scope). Video and typeset equations are reserved in the format for
later (`format.md` §8.2.7).

## Architecture

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  iPad app    │  │   Mac app    │  │  inkvault    │
│  SwiftUI +   │  │  SwiftUI via │  │  CLI         │
│  PencilKit   │  │  Catalyst    │  │  (mac+linux) │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       └────────────┬────┴─────────────────┘
             ┌──────┴──────┐
             │  InkRender  │  B-spline geometry, PDF, SVG
             ├─────────────┤
             │  InkVault   │  vault layout, note log, merge, keys
             ├─────────────┤
             │  Age        │  age v1 encryption (spec-exact)
             └─────────────┘
```

The three library targets build on Linux with only Foundation, swift-crypto
and zlib. That rule exists for two reasons: it keeps the format independent
of Apple frameworks, and it lets cloud agents (Linux-only VMs) build and test
most of the project. Anything that imports UIKit, AppKit, PencilKit or
CoreGraphics lives under `Apps/`.

## Ink

PencilKit does the drawing. Its strokes are uniform cubic B-splines whose
control points carry location, width, opacity, force, azimuth and altitude.
We serialize those control points into our own JSON, not PencilKit's opaque
`dataRepresentation()`, so the format is open and the renderer can be pure
Swift. PencilKit's pixel eraser slices strokes into new strokes, so the
drawing stays vector; in our log that is one `removeStroke` plus the
surviving pieces as `addStroke`s.

Each page may also carry its recognised handwriting text (`format.md` §5.5):
produced on device by PencilKit's handwriting recognition (iPadOS 27) or
carried in by an importer (Notability ships its own), stored inside the
encrypted note body like everything else, and used to power search. It is
derived data, replaced as a whole, so it merges last-writer-wins per page.

## Encryption

Container: age v1 (age-encryption.org/v1), X25519 recipients, implemented in
Swift on CryptoKit / swift-crypto and validated against the public C2SP test
vectors and against the reference `age` CLI.

Why age and not GPG: one fixed modern construction (X25519, HKDF-SHA256,
ChaCha20-Poly1305, every chunk authenticated), no cipher negotiation, a
tiny spec, several independent implementations, and a stock CLI that reads
our files. The key layer is behind a small protocol so an OpenPGP backend
could be added later if ever wanted.

Keys: an age identity is one line of text. The app imports and exports it
freely. A vault lists one or more recipient public keys and every note is
encrypted to all of them. The identity may additionally be stored in the
vault passphrase-wrapped (`age -p` compatible) for convenience; on device it
sits in the Keychain, optionally behind Face ID.

age does not sign. To stop someone with write access to the storage from
planting a note that decrypts, every plaintext carries an HMAC keyed by a
per-vault secret that only key holders can decrypt. The stock-CLI recovery
path simply skips the tag.

## Storage and sync

A vault is a folder. The app reads and writes files; sync is whatever moves
the folder: on-device, a Files-app provider (iCloud Drive, SMB, Nextcloud,
Dropbox, ...), a built-in WebDAV client (phase 3), or a zip through the
share sheet. Providers see UUID file names, keyed-hash blob names with their
kind (image, pdf, audio, …), sizes (blobs padded to a size class) and times,
nothing else.

## Append-only note log

A note is a folder of immutable encrypted revision files. Every save appends
a *delta* (strokes added or removed, metadata set) stamped with a device id,
a per-device sequence number and a hybrid logical clock. Periodically a
device writes a *snapshot* that records which deltas it includes. Deltas and
snapshots older than a retention window are compacted away.

Consequences:

- Sync tools only ever see new files, so no conflict copies.
- Concurrent edits are two branches; ink merges by set union of stroke ids
  (remove always wins), metadata merges last-writer-wins per field.
- History is the log; restore writes a new delta, so history itself is
  append-only. Restored strokes and pages get new ids with `parent` naming
  the old ones; revisions removed by compaction are no longer restore points
  (`format.md` §5.7).
- Recovery without the app reads the newest snapshot; at worst the deltas
  since it are lost, never the note.

Known limitation: two devices slicing the same stroke concurrently keep both
sets of pieces (overlapping duplicates). Acceptable for one person.

## Attachments

Images, PDFs, audio and transcripts are immutable *blobs* in the note's own
`att/` folder, named by an HMAC of their content hash under the vault secret
(no plaintext hashes on storage; the name is also the integrity tag),
deduplicated within the note, and collected per note only when no surviving
revision of that note references them. Text boxes (full Unicode), images and
PDF pages are *placed items* on a page with LWW geometry and text, on integer
z-layers, always drawn below the ink. Recordings belong to the note; strokes
drawn while recording carry the recording time. A recipient (device key)
change rewrites blob headers when a device is added and re-encrypts blobs
when one is removed or keys move to post-quantum. Details and alternatives:
`docs/attachments.md`; format: `format.md` §8.

## Export

One renderer evaluates the B-splines and writes vector PDF and SVG. It is used
by the apps' share sheet and by the CLI, so exports from a backup match
exports from the app. Textured inks (pencil, crayon, watercolor) are
approximated; pen, monoline and marker are faithful.

## Distribution

Public GPL-3.0-or-later repository on GitHub. App Store distribution needs the paid
developer account (undecided); otherwise personal installs via Xcode. GPL code
in the App Store is fine while the copyright is held by the project owner;
contributions will need a contributor agreement or a license exception
before the app ships there.

## Linux

The CLI is the Linux face of the project: it builds natively, is published as
a static binary from CI, and covers everything that does not need a pen:
key management, unlock, verify, recovery, bulk export to PDF and SVG. A Linux
viewer is possible later on the same core.
