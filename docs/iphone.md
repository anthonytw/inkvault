# iPhone (reader)

The iPhone app is the iPad app's target with the iPhone device family added
(`TARGETED_DEVICE_FAMILY = "1,2"`): one target, one bundle id, one code base. It is a
**reader**: browsing, searching, opening, exporting and unlocking work as on the iPad; writing
is possible but not emphasised. iPad and Mac behaviour does not change: everything phone-only
is gated on `Platform.isPhone` (`UIDevice` idiom `.phone`) or lives in `PhoneLayout.swift`.

## Layout

`NavigationSplitView` collapses to one stack in compact width, so an iPhone shows one
column at a time:

1. the vault (`SidebarView`: All Notes, notebooks, tags, Recently Deleted; the close-vault and
   key buttons),
2. the note list (`NoteListView`, search field with scopes; New Note stays in the bar, Select, Sort
   and Handwriting move into the overflow menu),
3. the note (`NoteCanvasView`).

The stack follows the selection (`CompactNavigation`): a note chosen anywhere (a row, a search hit)
shows the note, a sidebar item with no note shows its list. A `List(selection:)` pushes only when
the selection *changes*, so going back clears the selection of the column that was left (note on
back to the list; note and sidebar on back to the vault), and the same row can be tapped again.
Closing the note this way also closes its editor (a pop removes the view whose task would have).
A wide landscape iPhone (Pro Max) is a regular-width split view: the columns are shown by the
system and the stored column choice (`ColumnLayout`) is ignored on the phone, so a list can never
be left hidden.

## The note view

Read-first:

- **Pan and zoom.** The page fits the width (`fitWidth`); pinch zooms up to 4x, one finger pans.
  Infinite pages scroll one screen past the ink; finite pages end with "Next Page".
- **Page navigation** in the bottom bar (previous, "n / N", next) for notes with several pages;
  swiping up from the end of a finite page uses the "Next Page" button.
- **Light annotation.** The pencil button ("Annotate") switches finger drawing on. Until then the
  canvas draws nothing and the palette is hidden (`PhoneReading.drawingSuspended`,
  `PageCanvasHost.drawingSuspended`), so a stray finger only scrolls. Annotating shows the short
  palette (pen, marker, eraser, lasso; `PhoneReading.paletteCompact`), fingers draw
  (`drawingPolicy = .anyInput`), and the bottom bar gives way to a Pages menu so it does not sit on
  the palette. Annotation turns off again on the next note. Edits are ordinary deltas through
  `NoteWriter`, exactly as on the iPad. Read-only notes (deleted, legacy) never draw.
- **The rest** is in the overflow menu: Rename, Export (PDF, PNG, text), Version History, Keep Screen
  On, Tags, Paper, and the object-eraser size while annotating. The title in the bar renames the
  note on tap or long press.

## Search, export, history, keys

All of them are the shared views and model code: handwriting search over the recognised text
(Vision recognition also runs on the iPhone if switched on; the text is stored in the vault so
the iPad's recognition is searchable here), share/export sheets, the history browser and its
restore, and key unlock. Remembered keys use the Keychain with Face ID exactly as on the iPad
(`RememberedKeys`, "Remember on this iPhone"); the unlock screen is a sheet.

## Tests

- `PhoneLayoutTests.swift` (app tests): `CompactNavigationTests`, `PhoneReadingTests`, `PhoneCanvasTests`
  (a `PageCanvasHost` in windows of iPhone sizes: the page fits the width, reading mode disables
  drawing and keeps scrolling and zooming, annotating enables it, the iPad's canvas is not suspended) and
  `PhoneRootTests` (the root view hosted at an iPhone width). They run on the iPad destination
  as well (the idiom-dependent expectations follow the destination).
- CI runs them on an iPhone simulator after the iPad run (`scripts/app.sh test-phone`; the
  build products are shared, so it adds a boot and a few seconds). Run it locally the same way;
  `SEMPERE_SIM_ID` picks a simulator.
- Screenshots: `scripts/screenshots.sh iphone` (6.9", `docs/appstore/screenshots.md`).

## Not done

- Not tried on a physical iPhone: the layouts, the Face ID prompt and finger annotation are
  covered by simulator tests and by reading the code only.
- Swiping left and right to turn pages, a page-thumbnail strip, and word highlights on the page for
  search hits.
- The paper picker is in the overflow menu but has no iPhone-specific layout pass.
