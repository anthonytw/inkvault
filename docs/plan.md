# Plan

## Phase 0 — core library and CLI (Linux-buildable, cloud-friendly)

| # | Task | Owner target | Done when |
| --- | --- | --- | --- |
| 0.1 | age v1: X25519 + scrypt recipients, header, HMAC, STREAM payload, armor, Bech32 keys | `Sources/Age` | all C2SP CCTV vectors pass; round-trips with the `age` CLI |
| 0.2 | Vault: manifest, keys, vault secret, body framing + tag, revisions, HLC, merge, snapshot, compaction | `Sources/InkVault` | property tests for merge; concurrent-edit scenarios; `format.md` examples parse |
| 0.3 | Render: B-spline evaluation, variable-width outlines, paper, PDF writer, SVG writer | `Sources/InkRender` | golden-file tests; PDF opens in Preview; matches PencilKit interpolation on macOS |
| 0.4 | CLI: `keys`, `vault init/recipients/verify/list`, `export`, `recover` | `Sources/InkVaultCLI` | end-to-end test: init → write revisions → export PDF → `age -d` recovery |
| 0.5 | CI: Linux (swift:6.4-noble) + macOS; static Linux CLI artifact; cloud setup script | `.github`, `scripts` | green on PR, binary downloadable |
| 0.6 | Interop fixture vault committed under `Tests/Fixtures` with a throwaway key | tests | every target can load it |

## Phase 1 — iPad app

Xcode project under `Apps/`. SwiftUI shell; PencilKit canvas with the system
tool picker; paper layer; notebook/tag sidebar; autosave to the note log;
vault location picker (on device, iCloud Drive, Files-app folder); key
generate/import (AirDrop, QR, paste)/export; PDF share sheet; Face ID unlock.

## Phase 2 — Mac companion

Same target via Catalyst: menus, keyboard shortcuts, multi-window, drag and
drop export, bulk export, key management.

## Phase 3 — nice to have

History browser and restore; built-in WebDAV client; compaction UI;
handwriting search via PencilKit recognition (iPadOS 27); PNG export; stroke
dedupe after concurrent slicing; post-quantum recipient type.

## Working agreements

- One task → one branch → one PR → squash merge. CI must be green.
- `Sources/` never imports UIKit, AppKit, PencilKit, CoreGraphics or
  Compression. Linux CI enforces it by failing to build.
- Format changes go through `docs/format.md` first.
- Spawned agents: Sonnet 5.5 by default, Opus 5.5 for crypto and merge logic.
