# Handoff: where the project stands and how to continue

**Start here in a new session.** Then read `CLAUDE.md` (hard rules + gotchas),
`DESIGN.md`, `docs/format.md` (normative), `docs/plan.md`. Anything here that
disagrees with those files or with `gh pr list` is out of date: fix this file.
Last full rewrite: 2026-10-05, by the driving Opus session.

## The project in one paragraph

Open-source (GPL-3.0-or-later + App Store exception), end-to-end-encrypted
handwriting notes for iPad (iPadOS 26+) and Mac (Catalyst), a stripped-down
Notability. Vault = a plain folder of write-once age-encrypted revision files
(any storage: iCloud Drive, Files providers, WebDAV, a folder); user-owned keys;
PencilKit canvas with vector strokes; Notability importer; CLI (`inkvault`,
Linux + macOS) for recovery/export. Repo: github.com/anthonytw/inkvault
(public, GitHub only — never Gitea).

**Renaming to "Sempere"** (nod to *La sombra del viento*; "InkVault" is taken
on the App Store). See "Rename sweep" below; until it lands, code uses the old
names.

## Status (2026-10-05)

Merged on `main` (squash, CI green): #1–#8 Phase 0 (render, age, note log,
vault I/O, CLI, Notability importer), #10 app scaffold, #11 cloud setup script,
#12 CLI import/search, #13 PNG export, #14 history/restore, #15 vault browser,
#16 WebDAV sync, #17 PencilKit canvas, #18/#19/#31 importer fixes + fidelity
evaluation + full multi-zip backup (.ntb, versions, shapes, folder tags),
#20 debug-launch `~/` paths, #21 usability pass (vault as one item, progressive
iCloud load, layout, palette, rename, tag editor), #29 iCloud sync fixes
(auto-start, progress bar, no blank notes, scroll past ink, Keep Screen On),
#9/#32 docs.

Open PRs (all reviewed-or-in-review by cloud sessions; the driver merges):

| PR | Branch | What | State |
| --- | --- | --- | --- |
| #22 | design/attachments | Attachments FORMAT DESIGN (text boxes, images, audio + transcripts, PDF backgrounds); maintainer decisions final (PR comment 2026-10-05) | final revision in cloud session |
| #23 | feat/tag-set-merge | Tags as an observed-remove set (add wins), legacy `setMeta(tags)` compat; must adapt the importer's folder-tag helper | review session S1 |
| #24 | feat/app-keys-rename-eraser | Keychain-remembered keys (Face ID), long-press title rename, app-side object eraser with sizes + cursor | review session S2 |
| #25 | fix/untrusted-input-hardening | Parser hardening + seeded fuzz harness; adds `format.md` §9 "Untrusted input" (renumbered from §8 after #22 took §8) | review session S1 |
| #26 | chore/release-engineering | Release workflow, Homebrew, CHANGELOG, CONTRIBUTING (App Store exception, no CLA), SECURITY, App Store docs | review session S3 |
| #27 | feat/export-markdown-html | Obsidian Markdown + single-file HTML export | review session S3 |
| #28 | feat/paper-templates | Parametric paper + visual paper picker | review session S2 |
| #30 | feat/recovery-kit-backup | `keys paper` recovery PDF with QR, backup/verify/restore | review session S3 |
| #33 | feat/pq-recipients | MLKEM768-X25519 hybrid recipients; vaults post-quantum ONLY | review session S1 |

Cloud review sessions (started 2026-10-05 ~3:10 pm ET; prompts in
`~/Documents/sempere-sessions/`): S1 core+crypto session_018MdrghAVBvEAmFhniW8DY9,
S2 app session_01Aq6fucMojZT1mNSPWro6U2, S3 cli+release (Sonnet)
session_01MZXBxdMScB8hq5J7x52FZ2, design #22 session_011NXVJR4jRtMgSKEVY4NvYi.
Each merges main, reviews, fixes, gets CI green, comments on its PRs; none merges.

**Merge order** once reviewed: #25 → #23 → #33 (core; `format.md`: #22 is §8, #25 §9
after the renumbering), then #22 (design, docs), #24 → #28 (app), #30 → #27 → #26.
After each merge, later PRs may conflict: resolve locally in a worktree or tell
the owning session (`claude -p "…" --cloud <session_id>`).

## Decisions (made by the user; do not relitigate)

- **Post-quantum only:** vaults accept only the age hybrid ML-KEM-768 + X25519
  recipient (newest age spec, interop with `age` ≥ the first PQ release).
  Classic X25519-only keys are rejected ("create a new key"). Passphrases stay
  (they only wrap the key file in `keys/`). ML-KEM from CryptoKit (Apple) /
  swift-crypto (Linux), never hand-rolled.
- **Key flow:** one secret (the key). Create vault → print recovery kit → on
  each new device paste/scan/AirDrop the key once (or a passphrase if the user
  chose one) → Face ID afterwards (Keychain, #24). Default: no passphrase.
- **Licensing:** GPLv3 + App Store exception (§7 additional permission), no
  CLA. All deps are Apache-2.0 (swift-crypto incl. vendored BoringSSL,
  argument-parser, asn1) + zlib: GPL-compatible.
- **Export compliance:** mass-market, standard published algorithms, full
  strength.
- **Attachments design (#22):** per-note storage `notes/<id>/att/`, keyed-hash
  names, Padmé padding, LWW item fields, integer z-layers (0 background, 100
  content, ink above), full Unicode (system fonts in app, glyph-subset
  embedding in exports; Noto on Linux), Spanish localization + reserved `math`
  (LaTeX) and `video` items, settings panel (audio codec/quality, EXIF strip on
  by default, rewrap modes), auto rewrap policy (add device = header-only;
  remove device / PQ migration = full re-encrypt) with settings, time-stamped
  transcript segments, `rec: {id, at}` ink–audio sync, Poppler on Linux for PDF
  backgrounds in SVG/PNG (else placeholder), "PDF + attachments" export option,
  unused-attachments index in Settings, on-device AI only.
- **Notes are keyed by UUID; duplicate titles are fine everywhere.** Notebooks
  are `/`-separated paths shown as a tree. Folder names become tags on import.
- **Pages vs pageless:** per-note choice (paged = reorderable fixed pages,
  pageless = one infinite page) — app task, not started.

## Personal data

`data/` is git-ignored: the user's full Notability backup as three Google Drive
parts `Notability-20261005T121200Z-1-00{1,2,3}.zip` (pass all three together:
928 `.note`, 603 `.ntb`, 395 Notability PDF exports) and the latest fidelity
report `data/eval-full/`. `data/README.md` says the same. Never commit, quote or
paste its contents (code, tests, docs, commits, PR bodies, other agents).
Real-data tests are gated on `INKVAULT_NOTABILITY_SAMPLES`; scratch output goes
under `data/<name>/` and is deleted when done. Keep `data/`: re-imports are
needed after the PQ switch and for release.

Importer results on the full backup: 640 imported (629 `.note`, 6 `.ntb`-only,
5 separate versions of divergent copies), 891 skipped (identical copies, older
versions, superseded `.ntb`), 0 failed. Fidelity vs Notability's PDFs: 753
inked pages, F1 median 1.000 (p10 0.998), chamfer median 0.013 pt. Not imported
yet: PDF/image backgrounds, typed text, media/recordings (attachments work).

## Test vault and the user's iPad

- iPad: "antpad", iPad Pro 12.9" 4th gen (A12Z, Face ID, Pencil 2, no hover),
  **iPadOS 26.7.1, cannot update to 27** — every feature must work on 26.
  UDID 00008027-001D30E02131802E.
- Test vault: iCloud Drive `InkVault/Notes.inkvault` (127 notes from an old
  partial backup, classic X25519 key `~/.config/inkvault/identity.key`). To be
  REBUILT after #33 + rename: new post-quantum key, full backup import with
  folder tags. Put the key on the iPad with `pbcopy < key`, clear the clipboard
  after ~3 min.
- Device builds: `xcodebuild … -destination 'id=<UDID>' -allowProvisioningUpdates
  DEVELOPMENT_TEAM=6X3PT3FXGA build` then `xcrun devicectl device install app`
  / `process launch`. Never commit `DEVELOPMENT_TEAM`. A scratch worktree
  `.worktrees/device` is used for this.
- Debug on the device without the user: DEBUG launch env vars (`CLAUDE.md`),
  `devicectl device copy to/from --domain-type appDataContainer`, `--console`
  for logs. Ask the user to set Auto-Lock to Never while plugged in.

## Apple developer / App Store / TestFlight

Paid Apple Developer Program active (team 6X3PT3FXGA, individual; same ID as
the old personal team). App Store Connect record **"Sempere"** (iOS + macOS),
bundle id **`io.github.anthonytw.sempere`** (registered). API key: Key ID
`3M856V593J`, Issuer `24e225fb-771e-4dc7-b322-632d16493446`, file
`~/.config/sempere/AuthKey_3M856V593J.p8` (0600). Next: after the rename sweep,
archive a signed Release build with the new bundle id, upload to TestFlight via
the API key (`xcodebuild -exportArchive` / `xcrun altool` or `notarytool`-style
upload), add the user as internal tester; set `ITSAppUsesNonExemptEncryption`
per the export decision. Optional later: CI uploads on merge.

## Rename sweep (do after the open PRs merge)

One PR: app name "Sempere", bundle `io.github.anthonytw.sempere`, repo →
`anthonytw/sempere` (GitHub rename keeps redirects; update remotes, the cloud
environment's repo, docs), CLI `sempere`, Swift modules `Sempere*` (Sempere,
SempereRender, SempereImport, SempereWebDAV, SempereCLI; app target),
vault extension `.sempere` + UTType, format ids (`sempere/1`, new file magic,
HMAC/KDF labels — breaks existing vaults, fine pre-1.0), Keychain service,
UserDefaults keys, DEBUG env vars (`SEMPERE_DEBUG_*`), `~/.config/sempere/`,
docs. Then rebuild the test vault and do the first TestFlight build. Then run
one `/ultrareview` (user has 3 free cloud multi-agent reviews; user-triggered).

## How work gets done (what worked, what didn't)

- **One task → one branch → one PR → squash merge, CI green.** Agents never
  merge; the driver session reviews and merges. Every review so far found real
  bugs (several data-loss class) — never merge unreviewed code.
- **Cost model (important):** the user's "Cloud session credit" (~$250) covers
  ONLY cloud *sessions*. Routines (RemoteTrigger / `/schedule`), Projects,
  remote control and local agents all draw the user's **plan limits**. Prefer
  cloud sessions for big work; keep local agents for things that need the Mac
  (Xcode, simulator, the iPad, private `data/`). Prefer Sonnet where enough;
  don't fan out without asking.
- **Starting a cloud session from the Bash tool:**
  `PTY_SECS=180 PTY_STOP_ON_URL=1 python3 ~/.claude/scripts/cloud-session-pty.py
  claude [--model sonnet] --cloud "$(cat prompt.txt)" --ref main`, run from a
  CLEAN clone of the repo (no `data/`). The script provides a pty, answers the
  folder-trust prompt, and strips inherited `CLAUDE_CODE_*`/`CLAUDECODE` env
  vars — without that, `--cloud` silently uploads a "seed bundle" and the
  session gets **403 on push** (its unpushed work is unrecoverable; teleport
  only fetches pushed branches). Check `RemoteTrigger get_run_log <session_id>`:
  "Fetching/Cloning repository" = good, "Cloned from seed bundle" = bad.
- **Messaging a running session:** `claude -p "msg" --cloud <session_id>
  --output-format json` (`-p` is required; without it the error says attaching
  is "not enabled for your account").
- **Cloud VM:** Ubuntu, no Xcode. It builds/tests `Sources/` + `Tests/`; app
  code is compiled only by the GitHub Actions `app` job (push → `gh pr checks
  --watch` → `gh run view --log-failed`). The `inkvault` environment's setup
  script (`scripts/cloud-setup.sh`) installs Swift 6.4.0 into /usr/local/bin.
  Sessions use GitHub MCP tools (the VM's `gh` token is invalid).
- **Local agents:** create the worktree yourself
  (`git worktree add .worktrees/<name> -b <branch> origin/main`) and point the
  agent at it; never the Agent tool's `isolation: worktree` from `dev/` (it
  branches the bootstrap repo). Remove worktrees after merge.
- **Racing:** if a review session is still active on a branch, don't fix the
  same branch locally — it will push first and you'll duplicate work.
- **Briefs** must be self-contained: reading list, scope, API shape, tests,
  process (branch, merge-not-rebase, push, PR, don't merge), privacy rules,
  iPadOS 26 constraint, co-author line.
- **Waiting:** use background commands / Monitor with until-loops; never chain
  sleeps. `gh pr checks --watch` exits non-zero on failure — never chain
  `gh pr merge` after it without checking.
- **Docs-only PRs** have no CI checks; merge directly.
- **macOS shell:** `rm` is aliased interactive — use `/bin/rm`; `grep -r` from
  `dev/` skips sub-repos.

## CI

CI (`.github/workflows/ci.yml`) is gated so that runs are not wasted. macOS
runners are scarce: every run needs two of them, and on 2026-10-05 eleven runs
queued for up to 30 minutes.

- **Draft PRs run nothing.** Open work as a draft (`gh pr create --draft`) and
  push as often as you like. Run `gh pr ready <n>` when you want CI or a
  review; later pushes to a ready PR run CI again.
- **A newer push to the same PR cancels the older run.**
- **Only affected jobs run.** Docs-only changes run nothing. CLI, importer and
  WebDAV changes skip the app job. App-only changes skip Linux and macOS.
  `main` always runs everything.
- **On demand:** `gh workflow run CI --ref <branch>` checks any branch.
- **PRs skip what only matters for shipping.** The static Linux release build
  and the Mac Catalyst build run on `main` only. Tests run with `--parallel`.
- **Age is compiled with `-O` even in debug builds** (`Package.swift`).
  Unoptimized scrypt made the passphrase tests take minutes: 37 s for one test
  on macOS CI, and 138 s for one app test. Keep that flag.
- Tell every cloud session in its prompt: draft PR first, `gh pr ready` once
  the work is done and the local `swift test` passes.

## Lessons learned (technical, beyond CLAUDE.md gotchas)

- "No ink on the iPad" was iCloud (dataless real-name files on 26.7.1, folders
  listed before contents), not rendering: verify on the device with a DEBUG
  snapshot from a local copy before theorising about renderers.
- The simulator renders PencilKit faithfully; a 2020 iPad Pro on 26.7.1 drew a
  real imported note identically.
- Notability backups from Google Drive keep every old copy of moved/renamed
  notes; pick the newest per uuid, keep divergent ink as a version note.
- The first "backup" was only part 2 of a 3-part Drive download — always check
  for `-00N` siblings.
- Canvas snapshot tests flake on cold CI simulators (PencilKit draws tiles
  async): retry per band, never widen tolerances.

## Roadmap

The roadmap is in `docs/ROADMAP.md`: tables by component (shared library,
CLI, iPad app, macOS app) and the order of work.

Phase 1 task detail (historical, for reference):

2. **Phase 1, iPad app** (needs Xcode on the Mac or the macOS CI runner;
   Opus for 3a/3c, Sonnet for the rest). Split:
   - 3a **done** (branch `feat/ipad-app-scaffold`): `Apps/InkVault/InkVault.xcodeproj`,
     hand-maintained with folder-synchronized groups (no XcodeGen/Tuist),
     scheme `InkVaultApp`, iPadOS 26, Catalyst on, links the package's
     `InkVault` + `Age` products. Shell: `AppModel` (`@Observable`,
     `@MainActor`) opens a vault folder locked, unlocks with a pasted
     identity or a stored key file's passphrase, loads `Vault.summaries()`
     off the main actor and filters by sidebar selection (all, notebook,
     tag, deleted); `RootView` is a three-column `NavigationSplitView`
     (sidebar, note list, placeholder canvas) with a folder picker and an
     unlock sheet. Tests: Swift Testing in `InkVaultAppTests` against the
     fixture vault. Build/run: open the project in Xcode and run on an iPad
     simulator, or `scripts/app.sh test` / `scripts/app.sh catalyst`
     (CI job `app`). The folder picker does not persist access yet: 3b adds
     bookmarks, iCloud, vault creation and a real sidebar.
   - 3b **done** (branch `feat/app-vault-browser`): vault browser.
     `VaultLibrary` (recent vaults as bookmarks in
     `Application Support/InkVault/recents.json`, vault creation, folder-name
     validation), welcome screen (recents, vaults in the app's Documents folder,
     New Vault, Open Folder), `NewVaultView` (name, "On This Device" or any
     picked folder, generate an X25519 key or paste an `age1…` recipient,
     optional passphrase-wrapped copy in `keys/`; a generated key is shown once
     with copy/share), reopen of the last vault on launch, stale bookmarks
     re-saved, dead ones dropped with a message and the folder picker. Sidebar:
     rename notebook (applies to every note in it, deleted ones too). Note list:
     title search, sort (modified/title), new note (title, paper, notebook),
     context menu / swipe: add/remove tag, move to notebook, delete, restore.
     Every edit is one delta through `NoteWriter.append` with the same
     `DeviceClock` as the canvas (device id and clock in
     `Application Support/InkVault/device.json`; `Vault.apply` in
     `Edit.swift` stays for the CLI), the app writes no vault file itself. Tests: `BrowserTests` (app), `EditTests` (package).
     Leftovers: iCloud Drive works only through the picker (a folder inside
     iCloud Drive; the ubiquity container needs the iCloud entitlement
     `com.apple.developer.icloud-container-identifiers` +
     `com.apple.developer.ubiquity-container-identifiers` and a paid team, so
     `url(forUbiquityContainerIdentifier:)` is not used); evicted iCloud
     files are downloaded before reading and on every reload, with progress
     and cancel (`CloudVault.swift`, `docs/io.md` "iCloud Drive"; untested
     against real iCloud in CI, the simulator has none). Notebooks are a
     tree of `/`-separated paths (`format.md` §5.4, `Notebooks.swift`):
     selecting a folder shows its sub-folders' notes, rename/move rewrites
     the prefix of every descendant. Bookmarks on
     Catalyst use plain options (`.withSecurityScope` is not in the Catalyst
     SDK) and are untested on a sandboxed Mac build; the "On This Device"
     folder is not exposed in Files (needs `UIFileSharingEnabled` /
     `LSSupportsOpeningDocumentsInPlace`); vaults cannot be deleted or renamed;
     the new-vault key is not stored in the Keychain (3d); the empty notebook
     does not exist without a note (notebook is a note field).
   - 3c **done** (branch `feat/app-canvas`): `NoteCanvasView` shows one page
     at a time (`PageCanvasView`: `PKCanvasView` + system `PKToolPicker`,
     `PaperView` vector ruling from `InkRender.PaperRenderer` under it, fit
     to width, pinch to 4x; infinite pages grow 400 pt below the ink and save
     the new `pageSize`). Conversion in `StrokeConversion.swift`; masked
     (pixel-erased) strokes become one stroke per `maskedPathRanges` range via
     the Linux-tested `BSpline.substroke` (InkRender). Stable ids:
     `StrokeLedger` (pure, per page) matches canvas strokes by an O(1)
     content fingerprint (`CanvasStrokeInfo`) as a multiset, mints fresh ids
     for new content, infers `parent` (retired same-content stroke → same
     path signature → same family with containing bounds), revives ids whose
     removal is not on disk yet. `NoteEditor` debounces (1.5 s) into ONE
     delta per pause and flushes on page switch, background, note switch and
     vault close; `NoteWriter`/`DeviceClock` (actors) pick `seq`, tick the
     package `HybridClock` and keep `DeviceState` in Application Support.
     AppModel has a generation token so late `unlock`/`openVault`/`reload`/
     `openEditor` results after `close()` are dropped (`CancellationError`).
     Works on iPadOS 26 (the user's iPad cannot run 27; no 27-only API is
     used); tests pass on iOS 26.5 and 27 simulators. Left: no UI tests and no
     run on real hardware yet (pixel eraser verified with synthetic masks);
     the note list does not refresh its stroke counts after edits; remote
     changes arriving while a note is open are not merged into the canvas
     until it is reopened; no page delete/reorder; the app never writes
     snapshots; `reed` ink is stored as `fountainPen`.
   - 3b + 3c merge (#15 onto #17): the generation token also guards the
     iCloud download wait, browser edits (`refresh`), `createVault` (a vault
     created while another was opened is returned with its key, not opened)
     and the unlock after it; `close()` releases folder access only after the
     editor's last save and any browser edit in flight; the canvas reads and
     writes under `NSFileCoordinator` in iCloud Drive (`NoteEditor.open(...,
     coordinated:)`, `NoteWriter`); deleting or restoring the open note
     reopens it (read-only / editable).
   - 3d Keys: generate on device, import by paste/QR scan/AirDrop (`.key`
     file UTType), export (QR, share sheet), Keychain storage behind
     Face ID, passphrase-wrapped key file option; add second recipient
     flow ("add this Mac's key").
     **Keychain storage done** (branch `feat/app-keys-rename-eraser`):
     after a manual unlock (passphrase or pasted key) the unlock sheet offers
     "Remember on this iPad" (on) and "Also sync via iCloud Keychain" (off);
     a vault with a remembered key unlocks after Face ID as soon as it opens,
     falling back to the form when cancelled, missing or broken (a key that
     no longer opens the vault is offered for replacement). Sidebar key menu:
     "Forget Key for This Vault". `VaultKeyStore` (protocol) /
     `KeychainVaultKeyStore` (one generic-password item per vault id, service
     `io.github.anthonytw.inkvault.vault-key`, label "InkVault — <name>"),
     `RememberedKeys` (observable, separate from `AppModel`), tests with
     `FakeKeyStore`. Untested on hardware: Face ID prompts, iCloud Keychain
     sync, Catalyst keychain (needs a signed build). Still open in 3d: key
     generation/export/QR/AirDrop, add-recipient flow, offering to remember
     the key of a newly created vault.
   - 3e Export: PDF via `InkRender` through the share sheet; whole-vault zip
     dump; `verify` screen.
   - 3f Recognition + search: iPadOS 27 PencilKit recognition → `setPageRecognition`
     per page after edits; search field over recognition text with word-box
     highlights.

## History and restore (how it works)

- A restore point is a revision; the note as of R is
  `NoteReducer.reconstruct` of every revision ordered `≤ R` by
  `(hlc, device, seq)`. There is no parallel merge implementation.
- `NoteHistory.restoreOps(current:target:)` diffs two states into one delta.
  Items correspond by id or by `parent` (for strokes also same ink/points/
  transform), which is what makes a repeated restore a no-op.
- Pages gained an optional `parent` (`format.md` §5.5) so a re-created page
  names the one it restores; old readers ignore it.
- Completeness after compaction: gone revisions are the `(device, seq)`
  listed in some snapshot's `included` without a file. A point is complete if
  each is covered by a snapshot `≤` it or provably after it (`Completeness`
  in `History.swift`; ranges are compared, never enumerated, since `upTo` is
  read from a file). An unreadable snapshot makes every point incomplete. This
  is conservative: some points that could be rebuilt are reported incomplete.
- Re-added strokes render above the strokes that stayed (new `origin`); exact
  historical z-order is not restored.

## Gotchas collected so far

PencilKit (from 3c): `PKStrokePoint` keeps locations, sizes and times as
Float32 and quantizes opacity/azimuth/altitude (~1e-4; altitude even drifts on
every re-wrap), so conversion round trips are equal within 2e-4, not bit for
bit. `PKStroke.id`, `substroke(range:)` and `PKDrawing.erasePath` are
iPadOS 27 only; the user's iPad is capped at 26, so do not depend on them.


See `CLAUDE.md § Gotchas` (case-insensitive paths, FoundationXML, static
link flags, test-output grepping, the app project). Also: GitHub's `macos-26` runner has an
older compiler than local Xcode 27, so dense expressions that compile locally
can time out there; swift-crypto types are not `Sendable` on Linux (store raw
bytes); InkImport reads binary plists with its own `BinaryPlist` reader, since
`PropertyListSerialization` crashes on some hostile binary plists on Linux.
