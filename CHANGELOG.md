# Changelog

All notable changes to Sempere are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the CLI's version
(`Sources/SempereCLI/Version.swift`) follows [Semantic Versioning](https://semver.org/).
The section for a version is the body of its GitHub Release (`docs/releasing.md`).

## [Unreleased]

### Added

- CLI parity with the app's note browser and canvas: `sempere notes new`, `rename`, `tag`
  (`--add`/`--remove`), `move`, `paper` (whole note or `--page N`, every parametric kind and
  parameter), `delete`, `undelete`; `sempere notebooks list` / `rename` (the whole subtree);
  `sempere tags list`; `sempere pages list` / `add`. Each edit is one delta through the same core
  code as the app (`NoteOps`, `Vault.apply`), with `--json`. Policy: the CLI gets every feature
  first (`CLAUDE.md` "CLI first").
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
  holding them now decode instead of being reported unreadable; they are not merged yet (A1), so
  `snapshot` and `compact` refuse a note that has them rather than drop them.
- PDF page backgrounds in exports (attachments task C3). A new `SemperePDF` library reads PDFs
  from untrusted attachments (cross-reference tables and streams, object streams, incremental
  updates, rebuilding a broken file by scanning; bounded and fuzzed). PDF exports copy the original
  page in as a Form XObject (exact, PDF 1.7); SVG and PNG exports draw it with Poppler's
  `pdftoppm` when installed, run as a separate, time- and resource-limited process
  (`--pdf-renderer auto|poppler|none`, `--pdf-timeout`). Anything that cannot be drawn becomes a
  placeholder with a warning, never a failed export. Applies to notes once item ops are merged (A1).

### Changed

- `sempere notes list --notebook PATH` now lists the notes in that notebook and below it, comparing
  canonical paths by segment as the app's sidebar does (it compared raw names before).

- **Faster vault opening** (#54). Note summaries skip stroke geometry, are read in parallel,
  and are kept in an encrypted per-device cache (`docs/format.md` §10), so a 600-note vault
  lists in about 1.8 s instead of 21 s, and in 0.08 s when nothing changed. `notes list` gains
  `--no-cache`; `search` uses the same fast path. The app closes the unlock sheet as soon as the
  key is accepted, shows "Opening vault: n of m" while the list fills in, shows cached summaries
  at once on a reopen, and always says why the list is empty.

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
