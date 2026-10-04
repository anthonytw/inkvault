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

Importer results on the user's backup (git-ignored `data/`): 130 parsed, 127
imported, 3 same-uuid duplicates skipped, 0 failed; imports are scaled to
612 pt width with breaks every 803.25 pt. Not imported yet: PDF/image page
backgrounds (Phase 3) and dashed strokes (imported solid).

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

`data/` is git-ignored and holds the user's full Notability backup
(`Notability-…zip`, 130 notes) plus `data/samples/` and the bulk-import
scratch vault `data/bulk.inkvault`. Never commit, quote or paste its contents
anywhere (code, tests, docs, commit messages, PR bodies, chat with other
agents). Real-data tests are gated on `INKVAULT_NOTABILITY_SAMPLES`.

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

1. **CLI: `import notability` and `search`** (Sonnet; cloud OK). Wire
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
   - 3b Vault browser: create/open vault (on device, iCloud Drive via
     ubiquity container, any Files-app folder via security-scoped
     bookmark), notebook/tag sidebar, note list from `Vault.summaries()`.
   - 3c Canvas: `PKCanvasView` + system tool picker; lossless
     `PKStroke` ⇄ `Stroke` conversion (control points, ink, transform,
     stable ids via PencilKit's Identifiable strokes on iPadOS 27 or a
     side table); autosave = diff old/new drawing → `addStroke`/
     `removeStroke` ops → one delta per pause; pixel-eraser slices → remove +
     adds with `parent`; undo via the canvas's undo manager; paper layer
     under the canvas; infinite page growth.
   - 3d Keys: generate on device, import by paste/QR scan/AirDrop (`.key`
     file UTType), export (QR, share sheet), Keychain storage behind
     Face ID, passphrase-wrapped key file option; add second recipient
     flow ("add this Mac's key").
   - 3e Export: PDF via `InkRender` through the share sheet; whole-vault zip
     dump; `verify` screen.
   - 3f Recognition + search: iPadOS 27 PencilKit recognition → `setPageRecognition`
     per page after edits; search field over recognition text with word-box
     highlights.
3. **Phase 2, Mac via Catalyst**: menus, keyboard, multi-window, drag-out
   export, bulk export, key management UI.
4. **Phase 3** (`docs/plan.md`): history browser/restore, WebDAV client,
   compaction UI, PDF/image page backgrounds, PNG export, read-only access to
   newer formats, age CRLF diagnostic, PQ recipient type.

## Gotchas collected so far

See `CLAUDE.md § Gotchas` (case-insensitive paths, FoundationXML, static
link flags, test-output grepping, the app project). Also: GitHub's `macos-26` runner has an
older compiler than local Xcode 27, so dense expressions that compile locally
can time out there; swift-crypto types are not `Sendable` on Linux (store raw
bytes); `PropertyListSerialization` returns keyed-archiver UIDs as an opaque
object on both platforms (InkImport reads it via `Mirror`).
