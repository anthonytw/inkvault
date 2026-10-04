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

History browser and restore; built-in WebDAV client; compaction UI;
~~PNG export~~ (done: `inkvault export --format png [--dpi N]`, pure-Swift rasterizer in
`Sources/InkRender`, `docs/cli.md`); page backgrounds (PDF and image attachments: in the reference
Notability backup 26 of 130 notes are annotated PDFs and 4 hold images, all
imported today as ink on blank paper); stroke
dedupe after concurrent slicing; post-quantum recipient type; read-only
access to vaults of a newer format version (`format.md` §7; today `Vault.open`
refuses any `format` other than `inkvault/1`).

## Working agreements

- One task → one branch → one PR → squash merge. CI must be green.
- `Sources/` never imports UIKit, AppKit, PencilKit, CoreGraphics or
  Compression. Linux CI enforces it by failing to build.
- Format changes go through `docs/format.md` first.
- Spawned agents: Sonnet 5.5 by default, Opus 5.5 for crypto and merge logic.
