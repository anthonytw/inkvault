# Handoff: where InkVault stands and how to continue

Written 2026-10-04 by the session that scaffolded the project. Read this,
then `CLAUDE.md`, `DESIGN.md`, `docs/format.md`, `docs/plan.md`. Anything
here that disagrees with those files is out of date; fix this file.

## State

Phase 0 (core library + CLI) is **complete on `main`**, CI green on Linux
and macOS, static Linux binary published as a CI artifact.

| PR | What | Status |
| --- | --- | --- |
| #1, #5 | InkRender: B-spline sampling, outlines, PDF/SVG, input hardening | merged |
| #2 | Age: spec-exact age v1, 147 CCTV vectors, age-CLI interop | merged |
| #3 | InkVault: note log, HLC, merge, snapshots, compaction | merged |
| #4 | CI: static Linux CLI build (five explicit `-Xlinker -l…` libs) | merged |
| #6 | InkVault: vault layout, body framing + tag, keys, NoteStore, verify, fixture vault | merged |
| #7 | CLI: keys, vault, verify, export, recover, compact, snapshot (`docs/cli.md`) | merged |
| #8 | InkImport: Notability `.note` importer + page `recognition` field + `pageSize.breakHeight` (`docs/import-notability.md`) | merged |
| #13 | InkRender: PNG export (`Raster.swift` scanline filler with 8 sub-rows and exact horizontal coverage, non-zero union per draw command so a stroke blends once like the PDF; `PNGEncoder.swift` streamed zlib + adaptive filters; `PNGWriter.swift` paginates like the PDF; `--dpi`, 40 MP cap per image) + `inkvault export --format png` | merged |
| (open) | App usability pass (`feat/app-usability`): `.inkvault` as one item in Files (`VaultLocator`), progressive iCloud loading (`ProgressiveLoad`; list fills without pull-to-refresh), full-width canvas toggle (`ColumnLayout`), tool palette show/hide + compact (`ToolPalette`; PencilKit has no minimise API), note rename, visible tag editor + chips, case-insensitive tags, same-title notes tested | PR open; untested against real iCloud and on the iPad (simulator has neither) |
| (open) | Importer on the full 3-zip backup (`fix/import-full-backup`): copies/versions resolved across all inputs (newest `.note`, other ink imported as a separate version), `.ntb` reader (FlatBuffers; erase records), shapes, short per-curve arrays defaulted, folder tags (`--no-folder-tags`, `--tag`), thumbnail-aspect snapping (PDF stride fix), inset W/38.4; eval compares every page with Notability's PDF export | PR open, not merged |
| (open) | History and restore, core + CLI: `NoteHistory`/`Vault.restorePoints`/`state(noteId:at:)`/`restore`, page `parent`, `format.md` §5.7, `notes history`, `notes restore`, `export --at` | branch `feat/history-restore` |

Importer results on the user's full backup (2026-10-05, three Drive zips in
git-ignored `data/`: 928 `.note` + 603 `.ntb`): 640 imported (629 `.note`,
6 `.ntb`, 5 separate versions), 286 identical copies + 9 older versions +
596 superseded `.ntb` skipped, 0 failed. Pass all zips in one run. Fidelity
against Notability's own PDF export (`scripts/import-eval.sh --out
data/eval-full <zips>`): 753 inked pages, F1 median 1.000 (p10 0.998),
chamfer median 0.013 pt; no flagged note left with a suspected importer
cause (`docs/import-notability.md`, "Fidelity evaluation"). Imports are
scaled to 612 pt width. Not imported yet: PDF/image page backgrounds
(Phase 3), typed text, dashed strokes (imported solid); notes mixing paper
and PDF pages keep one `breakHeight`. The canvas stage has not been run on
the full backup (hours on the simulator).

Smoke test of the shipped CLI (works as of #7):

```bash
swift build -c release --product inkvault
F=Tests/InkVaultTests/Fixtures/sample.inkvault; K=Tests/InkVaultTests/Fixtures/sample.key
.build/release/inkvault vault info   --vault $F --identity $K
.build/release/inkvault vault verify --vault $F --identity $K
.build/release/inkvault export --all --format pdf --out /tmp/x --vault $F --identity $K
```

Note: global options (`--vault`, `--identity`, …) go AFTER the subcommand.

## Personal data

`data/` is git-ignored and holds the user's full Notability backup as three
Google Drive parts, `Notability-20261005T121200Z-1-00{1,2,3}.zip` (pass all
three together: 928 `.note`, 603 `.ntb`, 395 Notability PDF exports), plus the
latest fidelity report in `data/eval-full/`. `data/README.md` says the same.
Never commit, quote or paste its contents anywhere (code, tests, docs, commit
messages, PR bodies, chat with other agents). Real-data tests are gated on
`INKVAULT_NOTABILITY_SAMPLES`; scratch output goes under `data/<name>/` and is
deleted when done.

## Decided, not yet implemented

- **Encryption is post-quantum only.** Vaults accept only the age hybrid
  ML-KEM-768 + X25519 recipient (newest age spec). Classic X25519-only
  recipients are rejected with "create a new key", not offered as an option.
  Passphrases stay: they only wrap the key file in `keys/` (scrypt, symmetric).
- **Licensing:** GPLv3 plus an App Store exception (§7 additional permission),
  no CLA.
- **Export compliance:** mass-market, standard published algorithms, full
  strength.

## How work gets done (what worked)

- **One task → one branch → one PR → squash merge, CI green.** Agents never
  merge; the driver reviews and merges.
- **Local agents:** create the worktree yourself, then point the agent at it:
  `git worktree add .worktrees/<name> -b feat/<name> main`. Do NOT use the
  Agent tool's `isolation: worktree` from the `dev/` workspace root: it
  branches the bootstrap repo, not inkvault. Remove the worktree after merge.
- **Models:** Opus for crypto, merge/format logic, app architecture, format
  reverse engineering; Sonnet for views, CLI commands, docs, tests, review
  fix-ups. Fable is not needed for any remaining task.
- **Review:** `/code-review <branch-name> medium`, run from the main checkout.
  Passing a PR number from inside a worktree reviewed the wrong diff twice.
  Every review so far found real bugs; always run one before merging.
- **Cloud (preferred for Linux-only work, the user has ~$250 of credit):**
  create a one-time routine with the `/schedule` skill / `RemoteTrigger`
  (`run_once_at` 2–3 min out, environment `inkvault` =
  `env_01H7jGd6eTr5MTV3zWPt19A5`, repo `https://github.com/anthonytw/inkvault`,
  model `claude-sonnet-5-5` or `claude-opus-5-5`), then `list_runs` /
  `get_run_log` to follow it. `claude --cloud` needs a TTY and cannot be run
  from the Bash tool. The cloud VM is Ubuntu: it can do anything under
  `Sources/`, `Tests/`, `docs/`, CI; it cannot build `Apps/`.
  **Cloud sessions can only push/open PRs if the Claude GitHub App is
  installed on `anthonytw/inkvault`** (https://github.com/apps/claude/installations/select_target).
  The first routine did the whole static-build diagnosis and then got a 403
  on push. Check this before dispatching cloud work; if still missing, ask
  the user.
- **Briefs** for agents and routines must be self-contained: reading list,
  scope (directories they own), API shape, tests required, process (branch,
  commit style, push, `gh pr create`, do not merge), and the Co-Authored-By
  line the harness instructs.

## Next tasks (in order), with brief sketches

1. **CLI: `import notability` and `search`** — DONE on branch `feat/cli-import-search`
   (CLI 0.5.0; `docs/cli.md`; tests in `Tests/CLITests/CLIImportSearchTests.swift` with
   generated fixtures in `Tests/CLITests/Fixtures`; `--dry-run` imports into a temp copy of the
   vault; `NoteSummary.recognizedPages` feeds `notes show`). Original sketch: Wire
   `InkImport` into `Sources/InkVaultCLI` as `inkvault import notability
   PATH… --vault V [--notebook N] [--overwrite] [--dry-run] [--no-scale]`
   printing the `ImportReport`; add `inkvault search "term" [--json]` over
   `Page.recognition` text (case-insensitive, word boxes in `--json`), and
   `notes show` listing recognised text presence. Tests via the synthetic
   `.note` fixture in `InkImportTests` and the sample vault. Update
   `docs/cli.md`, plan rows 0.6/0.7.
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
3. **Phase 2, Mac via Catalyst**: menus, keyboard, multi-window, drag-out
   export, bulk export, key management UI.
4. **Phase 3** (`docs/plan.md`): history browser UI (the core and CLI are
   done: `Sources/InkVault/History.swift`, `format.md` §5.7), WebDAV client,
   compaction UI, PDF/image page backgrounds, read-only access to
   newer formats, age CRLF diagnostic, PQ recipient type.

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
bytes); `PropertyListSerialization` returns keyed-archiver UIDs as an opaque
object on both platforms (InkImport reads it via `Mirror`).
