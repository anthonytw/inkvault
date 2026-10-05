# InkVault — agent guide

Open-source, end-to-end-encrypted handwriting notes for iPad and Mac.
Read `DESIGN.md` (why) and `docs/format.md` (normative on-disk format)
before touching `Sources/`. `docs/plan.md` is the task board.

## Build and test

```bash
swift build                 # macOS or Linux
swift test                  # all targets
swift test --filter AgeTests
scripts/test-linux.sh       # on a Mac with Docker, or in a cloud VM: run tests in swift:6.4-noble
scripts/app.sh test         # iPad app: xcodebuild test on the newest iPadOS 26+ simulator
scripts/app.sh catalyst     # iPad app: unsigned Mac Catalyst build
```

The app lives in `Apps/InkVault/InkVault.xcodeproj` (open it in Xcode; scheme
`InkVaultApp`). It depends on this package as a local package (`../..`).

Toolchain floor is Swift 6.0 (`swift-tools-version: 6.0`, language mode 6).
Do not use features newer than Swift 6.0 in `Sources/`.

## Hard rules

- `Sources/*` and `Tests/*` must build on Linux: Foundation (plus FoundationNetworking in `InkWebDAV` only), swift-crypto
  (`import Crypto`), `CZlib` and swift-argument-parser only. No UIKit,
  AppKit, PencilKit, CoreGraphics, Compression, CommonCrypto, Security.
  Apple-only code goes under `Apps/`. Apple-only *tests* (e.g. comparing
  against PencilKit) are allowed behind `#if canImport(PencilKit)`.
- Files under a vault's `notes/` (revisions and each note's `att/` blobs) are
  write-once. Never add code that modifies them in place except the
  recipient-change rewrap (and blob rename) in `format.md` §3.3 and §8.1.5.
- Crypto: use swift-crypto primitives; never hand-roll a cipher or MAC.
  scrypt and PBKDF2 are the only primitives implemented locally
  (swift-crypto lacks them); they must have RFC test vectors.
- No network code in `Sources/` except the `InkWebDAV` target (`URLSession`, via
  `FoundationNetworking` on Linux). `scripts/check-portability.sh` enforces it.
- Keep the stock-CLI recovery path working:
  `age -d -i key FILE.age | tail -c +38 | gunzip | jq .`, and for blobs
  `age -d -i key notes/ID/att/NAME.KIND.age | tail -c +46 | head -c LEN`
  (`format.md` §8.1.7).

## Style

Swift 6 strict concurrency. `Sendable` value types for the model. No
force-unwraps outside tests. Errors are typed enums per module. Tests use
XCTest (Linux-compatible). Keep public API documented with `///`.

## Workflow

Branch per task, PR to `main`, squash merge, CI green. Commit messages:
`area: imperative summary`. Co-author line as the harness instructs.

## Gotchas

- macOS file systems are case-insensitive: never create two paths that differ
  only by case (`Sources/inkvault` vs `Sources/InkVault` collide). The CLI
  target is `InkVaultCLI` for exactly this reason; its product is `inkvault`.
- `swift test` prints Swift Testing's "0 tests" summary after XCTest's; the
  XCTest `Executed N tests` line is the one that matters.
- CLI tests run the built binary as a subprocess (see `Tests/CLITests`);
  do not add the executable target as a test dependency.
- On Linux, `XMLParser` (and `XMLDocument`) live in `FoundationXML`, and
  `URLSession` in `FoundationNetworking`. Guard the import with
  `#if canImport(FoundationXML)`; macOS has them in Foundation.
- `swift build --static-swift-stdlib` on Linux (Swift 6.4) fails to link with
  undefined ICU / `_FoundationCollections` / Synchronization / CoreFoundation
  symbols: the default build system omits Foundation's static dependencies.
  Pass them explicitly, as CI does: `-Xlinker -lCoreFoundation -Xlinker
  -l_FoundationICU -Xlinker -l_FoundationCollections -Xlinker
  -l_FoundationCShims -Xlinker -lswiftSynchronization -Xlinker -l_CFXMLInterface
  -Xlinker -l_CFURLSessionInterface -Xlinker -lcurl -Xlinker -lxml2` (the last four for FoundationXML and
  FoundationNetworking, used by `InkWebDAV`; libcurl and libxml2 stay dynamic). Do not put these in
  `linkerSettings` (they break dynamic builds and `swift test`).
- `Sources/` must also compile for iOS and Mac Catalyst (the app links it), not
  just macOS and Linux. Some Foundation API is macOS-only:
  `FileManager.homeDirectoryForCurrentUser` is unavailable there (use
  `NSHomeDirectory()`). `scripts/app.sh catalyst` catches these.
- The app target is `InkVaultApp` with `PRODUCT_NAME = InkVault` and
  `PRODUCT_MODULE_NAME = InkVaultApp`: a module named `InkVault` would collide
  with the package's `InkVault` library. Tests use `@testable import InkVaultApp`.
- `project.pbxproj` is hand-maintained and uses folder-synchronized groups
  (Xcode 16+): add or remove `.swift` files under `Apps/InkVault/InkVaultApp/` or
  `InkVaultAppTests/` without touching the project file. Only new targets,
  package products, build settings or resources need a pbxproj edit; keep object
  ids as 24 hex digits and check with `plutil -lint`.
- App tests read the package's fixture vault through a folder reference to
  `Tests/InkVaultTests/Fixtures` (copied into the test bundle as `Fixtures/`);
  copy the vault to a temp dir before anything could write to it.
- A fresh Xcode install may fail every `xcodebuild` with "A required plugin
  failed to load": run `xcodebuild -runFirstLaunch`. It also ships without an
  iOS simulator runtime: `xcodebuild -downloadPlatform iOS` (about 8 GB).
- App writes go through `NoteWriter` (`DeviceClock.swift`): canvas autosave and
  browser edits (`NoteWriter.append`) alike, one delta each, with the one
  `DeviceClock` the `AppModel` owns (device id and clock in Application Support).
  Never write vault files from `Apps/` any other way, and never tick a second
  clock on the same state file (`Vault.apply` is for the CLI and tests). Async
  `AppModel` work re-checks the `generation` token (`ensureCurrent`) after
  every await before publishing. Security-scoped URLs from the picker need
  `startAccessingSecurityScopedResource()` for the whole time the vault is used;
  vault bookmarks use `options: []` (no `.withSecurityScope` on iOS/Catalyst).
- The app's non-UI logic (`AppModel*.swift`, `VaultLibrary.swift`, their tests)
  can be typechecked and run on Linux with a scratch package that symlinks the
  files and shims the Apple-only URL bookmark and scoped-resource APIs; SwiftUI
  views cannot, only the CI `app` job builds them.
- Notebook names are `/`-separated display paths (`format.md` §5.4): use
  `NotebookPath` / `NotebookNode` (`Sources/InkVault/Notebooks.swift`), never
  `==` on raw names (`" A//B "` and `A/B` are the same notebook; `A/Bc` is not
  inside `A/B`).
- iCloud Drive vaults: evicted files are `.<name>.icloud` placeholders, or,
  on iPadOS 26 (seen on 26.7.1), dataless files under their real names with
  status "not downloaded" (`FakeCloud.evictDataless` in tests). A plain
  listing skips the stand-ins, so the vault or a note looks empty; a note
  folder iCloud has not listed yet is empty too and must be treated as
  pending, never as an empty note (`FakeCloud.unlist`). The app downloads them first and coordinates
  reads/writes (`CloudVault.swift`, `docs/io.md` "iCloud Drive"); this is
  app-only code, `Sources/` stays plain `FileManager`. The simulator has no
  iCloud: only the pure logic (`CloudScan.swift`) is tested there; the
  Linux scratch package needs shims for `isUbiquitousItem`,
  `startDownloadingUbiquitousItem`, `ubiquitousItemDownloading*` resource
  values and `NSFileCoordinator` as well.
- The app's deployment target is iPadOS 26 and the user's iPad cannot update
  to 27: any iPadOS 27 API (`PKStroke.id`, `PKStroke.substroke`,
  `PKDrawing.erasePath`, recognition) must sit behind `if #available` with a
  tested 26 path. Run `INKVAULT_SIM_ID=<iOS 26.x iPad> scripts/app.sh test`
  as well as the default (newest) simulator.
- PencilKit stores control points in reduced precision (Float32 locations,
  quantized opacity/azimuth/altitude): compare converted strokes within a
  tolerance, never with `==`. Stroke identity across canvas edits comes from
  `StrokeLedger`'s fingerprints, which are always taken from the `PKStroke`.
- `PKStrokePoint.size` is not the drawn width: a pen or monoline of size `s`
  is drawn `2s − 4` wide (invisible below 2), markers and textured inks
  differ again. Point sizes go through `NibSize` (StrokeConversion.swift);
  never pass a format `w` to PencilKit directly. `ImportedStrokeRenderingTests`
  pins the relation, so an iPadOS change to it fails there first.
  That relation was measured on the simulator and Mac Catalyst only. Strokes
  drawn on the user's iPad (iPad Pro 12.9" 4th gen) record pen sizes of about
  3.2 to 4.9 for tool widths 0.88 to 25.7, and monoline size 3.25 whatever
  the width, with the width carried inside the (opaque) `PKInk`; on hardware
  the drawn width may depend on that ink, which the simulator ignores. Check
  ink-width changes on a device, not only in tests.
- `PKToolPicker.init` restores PencilKit's own saved tools
  (`PKPaletteNamedDefaults` in the app's defaults) over the items it is
  given, and its saved eraser is the pixel eraser. `EraserPreference` drops
  that saved eraser entry before building a picker, so the object eraser is
  the default and the user's last choice (stored under `InkVault.eraserType`)
  wins. On iPadOS 26 the picker's pixel eraser is `.fixedWidthBitmap`: a
  `.bitmap` eraser item comes back as that.
- Debug builds open a vault and note from launch environment variables, for
  scripted simulator or Catalyst runs (`DebugLaunch.swift`):
  `INKVAULT_DEBUG_VAULT`, `INKVAULT_DEBUG_IDENTITY`, `INKVAULT_DEBUG_NOTE`
  (id prefix), `INKVAULT_DEBUG_SCROLL_Y`, `INKVAULT_DEBUG_ZOOM`,
  `INKVAULT_DEBUG_SNAPSHOT` (PNG of the canvas); paths may start with `~/` (the
  app's data container: on a real device, copy a vault in with `xcrun devicectl
  device copy to --domain-type appDataContainer`). With `xcrun simctl launch`
  prefix each with `SIMCTL_CHILD_`. Point it at a copy of a vault: the editor
  autosaves.
- `PKCanvasView` inverts ink colours in dark mode; the canvas forces
  `.light` because ink colours are stored as drawn on (light) paper.
- Vaults are one item in Files: `InkVaultInfo.plist` (referenced by `INFOPLIST_FILE`,
  outside the synchronized group so it is not copied as a resource) exports the
  `.inkvault` package UTType. `VaultLocator.resolve` maps whatever was picked
  to the vault folder (never upward: a pick inside a vault is an error, its scope
  does not cover the vault); `openVault(at:accessing:)` holds the security scope of the
  picked URL, not the derived one.
- iCloud notes load progressively (`ProgressiveLoad`, `AppModel+Cloud`): never
  await the whole vault before listing. Tests fake placeholders with
  `FakeCloud` (`ProgressiveLoadTests.swift`) and `CloudVault.Hooks`; the model
  takes `cloudHooks`, `cloudPollInterval`, `cloudWindow`. Anything that opens or
  edits one note calls `downloadNote` first (a fresh listing of its folder, not
  `pendingNoteIDs`): never write a delta while any of its revisions is missing.
  The editor's read re-checks with `CloudVault.requireLocal`, and a note that
  cannot be opened shows `editorFailure` in the detail pane, never a blank
  canvas. The sync loop never ends while a vault is open (idle pace after it
  settles) and starts when the vault opens, before unlocking; stalls go to
  `cloudSync.problem` (the list's bar), not an alert. Set
  `cloudIdleInterval` short in tests that wait for a recovery.
- Debug device runs against the user's iCloud vault: `INKVAULT_DEBUG_RECENT=1`
  opens the most recent vault through its bookmark (the picker's scope), with
  `INKVAULT_DEBUG_PROBE=1` (log how iCloud presents the files),
  `INKVAULT_DEBUG_EVICT=1|dirs|notes` (evict from this device first),
  `INKVAULT_DEBUG_WATCH=<s>` and `INKVAULT_DEBUG_OPEN_ALL=<n>` (open n notes,
  log page and stroke counts only). Read the log with `devicectl device
  process launch --console`. Never put note titles or content in logs.
- Infinite pages scroll one screen beyond both their ink and their stored
  height (`PageExtent.scrollHeight`); finite pages end with an Add Page / Next
  Page button below the page. "Keep Screen On" (`KeepScreenOn`) disables the
  idle timer only while a note is open and the scene is active.
- `NavigationSplitView` ignores a programmatic column change that arrives
  while the view is first being built, so the stored choice (`ColumnLayout`,
  `@AppStorage`) is never made to depend on selection state.
- `PKToolPicker` has no minimised/docked API (see `ToolPalette.swift`): the app
  can hide it (`setVisible`) and build a picker with fewer tools; the user
  minimises or docks the system palette by dragging it to an edge or tapping its
  collapse handle. Changing the compact option swaps the picker object.
- Tags match case-insensitively (`NoteOps.tagKey`); titles are never keys.
- Remembered vault keys (`VaultKeyStore.swift`, `RememberedKeys.swift`): the
  age identity text is stored only in the Keychain, never logged, never in
  `UserDefaults` or files. Device-only items are
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `SecAccessControl`
  `.biometryCurrentSet` (`.userPresence` without enrolled biometrics; a new
  Face ID enrollment invalidates the item, which reads as "no key").
  Synchronizable (iCloud Keychain) items cannot carry an access control or a
  `ThisDeviceOnly` class: reading one is gated by `LAContext.evaluatePolicy`
  in the app, and the UI says so. No entitlement is added: items use the
  app's default access group (its application identifier), which free
  personal-team builds have. Unsigned builds (CI, simulator tests) get
  `errSecMissingEntitlement`, so tests use `FakeKeyStore`, never the real
  Keychain. Face ID needs `INFOPLIST_KEY_NSFaceIDUsageDescription` (pbxproj).
  Generic-password items from apps are generally not listed in the Passwords app.
- The object eraser is the app's (`ObjectEraser.swift`, `EraserGeometry.swift`):
  PencilKit's `.vector` eraser has no size. When the picker's eraser is in
  object mode, `PageCanvasHost` disables `drawingGestureRecognizer` and
  `ObjectEraserController` takes the touches (Pencil, plus one finger when
  fingers draw; scrolling then needs two), removes every stroke whose sampled
  outline the swept capsule touches by setting `canvas.drawing`, and registers
  one undo step per gesture on the canvas's undo manager. The ledger turns
  that into ordinary `removeStroke` ops. The pixel eraser stays PencilKit's.
  Radius presets (`ObjectEraserSize`, page points) are in `UserDefaults`
  under `InkVault.objectEraserRadius`; the size menu is in the editor toolbar.
