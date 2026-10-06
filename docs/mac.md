# The Mac app (Mac Catalyst)

The Mac app is the iPad target built for Mac Catalyst: same sources, same
vault code. Phase 2 (`docs/ROADMAP.md`, "macOS app") adds what a Mac expects.
Everything Mac-only is gated on `targetEnvironment(macCatalyst)` or on
`Platform.isMac` (`MacSupport.swift`), so the iPad build is unchanged: no
menu bar entries, one window, the same pointer behaviour.

**Verification status.** The logic (command list, enabling, zoom steps,
window editors, key changes, PDF export, selection restore, folder-access
check) is covered by tests that run in the `app` CI job on the iPad simulator
and, as plain Swift, on Linux. Nothing here has been run on a Mac yet: menus,
drag to Finder, window restoration, the sandbox and pointer input need a
hand test on a Mac (list at the end).

## Menus and shortcuts

One type, `MenuCommand` (`MenuCommand.swift`), lists every command with its
title, shortcut and enabling rule; `MenuLayout` orders them into menus and
`AppCommands` (`AppCommands.swift`) turns that into SwiftUI. A feature that
adds a menu entry adds a case there (and a handler in `RootView.perform` or
`EditorCommands.perform`); `MenuCommandTests` fails when two commands share a
shortcut, a command is in no menu, or a plain key (one that would take typing
from a text field) is used.

Each window publishes a `CommandRouter` (its state for enabling, and what to
do for a command) as a focused scene value; the menu bar acts on the focused
window. With no window, only View > Library is enabled (`CommandGroupPlacement.windowList`, the natural home, is macOS-only).

| Menu | Command | Shortcut |
| --- | --- | --- |
| File | New Note… | ⌘N |
| File | Open Note in New Window | ⌥⌘N |
| File | New Vault… | ⇧⌘N |
| File | Open Vault… | ⌘O |
| File | Open Recent | submenu of the recent vaults |
| File | Reopen Last Vault | ⇧⌘T |
| File | Close Vault | ⇧⌘W |
| File | Reload Vault | ⌘R |
| Edit | Undo, Redo | ⌘Z, ⇧⌘Z (the system's: the canvas's undo manager, or the text field being edited) |
| Edit | Find Notes (focuses the title search) | ⌘F |
| Note | Rename Note… | ⇧⌘R |
| Note | Edit Tags… | ⌥⌘T |
| Note | Paper… | ⌥⌘P |
| Note | Previous Page, Next Page | ⌘[, ⌘] |
| Note | Add Page | ⇧⌘A |
| Note | Move to Recently Deleted | ⌘⌫ |
| Note | Restore Note | (none) |
| Tools | Pen, Marker, Pencil, Eraser, Lasso | ⌥⌘1 … ⌥⌘5 |
| Tools | Ruler (straight lines with a mouse) | ⌥⌘R |
| Tools | Show or Hide Tool Palette | ⇧⌘P |
| View | Zoom In, Zoom Out | ⌘=, ⌘- |
| View | Fit Page Width, Actual Size | ⌘0, ⌘1 |
| View | Hide or Show Note List | ⌥⌘L |
| View | Library (opens a library window when none is open) | ⌥⌘0 |
| View | Vault Keys (the key window) | ⌥⌘K |

⌘W closes a window as usual; it never closes the vault (⇧⌘W does). Zoom
steps are 1, 1.25, 1.5, 2, 2.5, 3 and 4 times the fitted page width
(`ZoomSteps`); Actual Size is one page point per screen point, within the
canvas's range. Tool commands select the tool in the system palette
(`PageCanvasHost.select(tool:)`); the compact palette has no pencil, so that
command does nothing there.

## Windows and state restoration

* **Library window** (`WindowGroup` id `library`): the sidebar, the note list
  and one note on the canvas, as on the iPad.
* **Note windows** (`WindowGroup(for: NoteWindowValue.self)`): one note each,
  opened from the note's context menu or File > Open Note in New Window.
  `NoteWindowValue` is `Codable` (vault id and note id, no path), so SwiftUI
  restores the windows that were open. A note window restored without a library
  window brings the library window up (after a second, if none appeared) to
  open and unlock the vault; the note then opens by itself. A window whose note
  belongs to another vault than the open one says so and offers to close.
* **Key window** (`WindowGroup` id `keys`; SwiftUI's single-instance `Window` scene is not available in the iOS SDK that the simulator CI builds, so repeating the command may open a second, identical window): see below.
* The library window saves its selection (sidebar item, note, vault id) with
  `@SceneStorage` and applies it once the same vault is unlocked again
  (`AppModel.restore`; a notebook, tag or note that is gone falls back to All
  Notes or no note).
* Multiple scenes are switched on for Mac Catalyst only
  (`INFOPLIST_KEY_UIApplicationSupportsMultipleScenes[sdk=macosx*]`); the iPad
  keeps its single scene.

**One editor per note.** All windows share one `AppModel`, one vault, one
`DeviceClock` and one edit gate, so every delta ticks the same clock. A note
has at most one `NoteEditor` (two would keep separate stroke ledgers and write
diverging deltas): while a window shows a note (`claimNote`), the library
window's detail pane shows "Open in Its Own Window" instead of opening it, and
takes it back when the window closes (`releaseNote`, once the window's last
save is written). An open that finishes after a window took its note, or after
its window closed, is dropped. Closing the vault, or changing the vault's keys,
saves and closes every editor first; a closed editor takes no more changes and
writes nothing (`NoteEditor.isShutDown`), and a note window always shows the
model's editor for its note (`windowEditors`), never a copy of its own. Only one
library window shows the canvas (`AppModel.canvasWindow`, "Show Here" in the
others): two canvases on one editor would each report a drawing without the
other's new strokes, which the ledger takes as erasures. A window's editor reads
handwriting like the pane's (the model's `recognizer` reaches it), and notes
open in a window are left out of "Recognize N Notes Now". Restored note windows
ask for at most one library window (`shouldOpenLibraryWindow`). Note > Move to
Recently Deleted (⌘⌫) is off while a search, rename or tag field may have focus.

## Drag a note out as PDF

Dragging a row of the note list to the Finder (or any app that takes files)
gives a PDF named after the title (`ExportFileName.pdf`: no path separators,
colons or control characters, at most 120 bytes, "Untitled" when empty). The
PDF is rendered when the drop asks for it (`NSItemProvider.registerFileRepresentation`),
after the open note's pending ink is saved and, in iCloud Drive, after the note
is downloaded (`AppModel.exportPDF`), with `SempereRender.PDFWriter`, the same
renderer as `sempere export`. A note with unreadable revisions is refused
rather than exported with pages missing. The file is plaintext, written under
`$TMPDIR/SempereExport/<model id>/<random id>/<title>.pdf`; the folder is
emptied when the vault closes and at launch, and files older than ten minutes
are removed on the next export. Bulk
export is the CLI's (`sempere export`); the share and export work in the app
adds its own menu entries to `MenuCommand`.

## Key window

View > Vault Keys (⌥⌘K) shows the keys the unlocked vault is encrypted to:
label, abbreviated public key with its SHA-256 fingerprint, the date added, a
mark on the key that unlocked the vault. From it:

* **Add Device Key…** pastes another device's public key (`age1pq1…`) with a
  label, or generates a post-quantum key for it, adds it, and shows the secret
  once (copy: local only, cleared after three minutes; the text is not
  selectable, so ⌘C cannot bypass that). The secret is shown whenever the
  vault already lists the key, even if the rest of the change failed or the
  vault was closed meanwhile. Classic X25519 keys are refused
  (`docs/post-quantum.md`). The sheet and the Remove dialog act only on the
  vault they were opened for (`KeyError.vaultChanged`).
* **Remove…** drops a key. The key that unlocked the vault, and the last key,
  cannot be removed. Removal rotates the vault secret and re-encrypts every
  note (`Vault.removeRecipient`, `docs/io.md` "Recipient changes").
* **Recovery Kit…** is the paper kit (`sempere keys paper`): the unlocked key as
  a QR code and checked text, to print (system print panel) or save as PDF. The
  PDF holds the secret key, and the dialog says so.

Adding and removing re-encrypt every file, which takes as long as the vault is
large and needs every note local in iCloud Drive (`downloadEverything`).
Open editors hold a copy of the vault with the old secret, so all of them are
saved and closed first, the vault is replaced (`adoptRewrapped`), and
`keyEpoch` makes every view open its note again. No editor opens while the
change runs (`isChangingKeys`), and one whose open began before it is dropped.
Edits from the note list wait on the edit gate meanwhile. If some files cannot be re-encrypted the change
stays pending (`KeyError.incomplete`) and the next try finishes it.

## Mouse and trackpad

There is no Pencil, so on a Mac:

* The canvas draws with any input (`drawingPolicy = .anyInput`), not "the
  Pencil if one is paired".
* The **object eraser takes the pointer** (`ObjectEraserController.pressTouchTypes`).
  It replaces PencilKit's gesture, and used to listen for the Pencil and
  fingers only, so on a Mac the default eraser did nothing.
* The pointer over the canvas is a circle the size of the ink tool's stroke at
  the current zoom (`PointerCursor.diameter`, 6 to 64 pt); the object eraser
  keeps its own cursor, the lasso and the pixel eraser the system arrow.
* **Ruler** (⌥⌘R) toggles PencilKit's ruler for straight lines.
* Two-finger scroll and pinch scroll and zoom the canvas, as PencilKit's
  scroll view does; click-drag draws.

Not done: smoothing or simulated pressure for mouse strokes (PencilKit
produces the strokes and gives a mouse constant force, so mouse ink has a
uniform width). Post-processing strokes would change what the format stores
for them; it is left until it has been tried by hand.

## Sandbox and saved folder access

See `docs/io.md` "Saved folder access (sandboxed Mac)". The entitlements for
Mac builds are `Apps/Sempere/Sempere.entitlements` (App Sandbox, user-selected
files read/write, app-scope bookmarks), applied to Catalyst builds only
(`CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`).

## To try by hand on a Mac

1. Open a vault from the open panel, quit, relaunch: does it reopen (sandboxed
   build: `scripts/app.sh catalyst` with signing, or Xcode)? A DEBUG build logs
   `SempereDebug folderAccess scoped=… listable=…` for every open.
2. Every menu entry and shortcut above, in the library window and a note window.
3. Open two notes in two windows, draw in both, quit and relaunch: both windows
   come back, the vault asks for its key (or Touch ID) once.
4. Drag a note to the Desktop; open the PDF in Preview. Drag one that is open
   with unsaved ink.
5. Add a key (paste and generate), remove it, print the recovery kit.
6. Draw with the mouse and trackpad, with each tool; erase with the object eraser.
