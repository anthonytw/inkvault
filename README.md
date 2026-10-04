# InkVault

A stripped-down handwriting notes app for iPad (and Mac), with the few features
that matter and nothing else:

- **Your keys, your notes.** Every note is an [age](https://age-encryption.org)
  file encrypted to keys you generate, import, export and back up yourself.
  No account, no server, no key you cannot take with you.
- **Sync is a folder.** A vault is a plain folder of encrypted files. Put it on
  the iPad, in iCloud Drive, on a NAS share, behind WebDAV, or zip it anywhere.
- **Nothing is ever lost quietly.** Each note is an append-only log of saves.
  History is browsable, edits from two devices merge, and sync tools never
  see a conflict.
- **Readable without the app.** `age -d` plus `gunzip` plus `jq` recovers any
  note. The `inkvault` CLI exports PDF and SVG from a backup on any machine.
- **Real ink.** Strokes are vectors (PencilKit B-splines), so erasing, export
  and search stay clean.

Free software under the GPL-3.0-or-later, no telemetry. The `inkvault` CLI is a
first-class Linux citizen: keys, unlock, verify, recovery and PDF/SVG export
all run natively on Linux, and CI publishes a static Linux binary.

## Layout

| Path | What |
| --- | --- |
| `Sources/Age` | Spec-exact Swift implementation of the age v1 format |
| `Sources/InkVault` | Vault layout, note log, merge, keys |
| `Sources/InkRender` | Stroke geometry, PDF and SVG writers |
| `Sources/InkVaultCLI` | Command-line tool: keys, verify, export, recover |
| `Apps/InkVault` | iPad app, Mac via Catalyst (Xcode project, phase 1; a shell so far) |
| `docs/format.md` | The on-disk format, normative |
| `DESIGN.md` | Why it is built this way |
| `docs/plan.md` | Phases and task board |

Everything under `Sources/` builds and tests on Linux and macOS with
`swift test`. The apps need Xcode 26 or newer: open
`Apps/InkVault/InkVault.xcodeproj` (scheme `InkVaultApp`), or run
`scripts/app.sh test` (iPad simulator) and `scripts/app.sh catalyst` (Mac).

## Status

Phase 0 (core library and CLI) is nearly done: the `inkvault` CLI (keys, vault, verify, export, recover; see `docs/cli.md`) works on Linux and macOS. The iPad app is a scaffold: it opens and unlocks a vault and lists its notes; drawing comes next.
