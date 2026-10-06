# Changelog

All notable changes to Sempere are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the CLI's version
(`Sources/SempereCLI/Version.swift`) follows [Semantic Versioning](https://semver.org/).
The section for a version is the body of its GitHub Release (`docs/releasing.md`).

## [Unreleased]

### Added

- **Paged and pageless notes** (`docs/format.md` §5.4.3, #52): a note has fixed-size pages
  or one infinite page, and switches between them without deleting or moving ink
  (`sempere notes layout ID paged|pageless`; in the app, the Page Layout menu). In the app,
  paged notes add a page after the current one or at the end, delete (with undo),
  duplicate, and reorder pages by dragging in a thumbnail strip; each gesture is one delta.
- Attachment model types (`docs/format.md` §8; task A0): placed items (text, image, PDF page, and
  unknown kinds kept verbatim), recordings, transcripts, blob references and their six ops. Revisions
  holding them now decode instead of being reported unreadable; they are not merged yet (A1), so
  `snapshot` and `compact` refuse a note that has them rather than drop them.

### Changed

- Exports cut pageless pages at gaps in the ink near each sheet height instead of through
  lines of handwriting (`export --breaks gaps`, the default; `--breaks fixed` keeps the old
  cuts). Ink that a concurrent edit left below a fixed-size page is exported on an extra page
  instead of being dropped.
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
