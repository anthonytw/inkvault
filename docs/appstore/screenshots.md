# App Store screenshots

The screenshots are generated, not taken by hand: a UI test launches the debug app on a **synthetic
demo vault** built in code and saves what it sees. Nothing is uploaded to App Store Connect; the
maintainer does that with the PNGs.

```bash
scripts/screenshots.sh ipad    # iPad Pro 13-inch simulator -> build/screenshots/ipad/*.png
scripts/screenshots.sh mac     # Mac Catalyst (best effort)   -> build/screenshots/mac/*.png
scripts/screenshots.sh         # both
```

It needs Xcode with an iOS 26+ runtime and an "iPad Pro 13-inch" simulator (`SEMPERE_SIM_ID` picks
another; `SEMPERE_SHOTS_OUT` changes the output folder). In CI, run the **CI** workflow by hand with
`screenshots` ticked (`gh workflow run CI --ref <branch> -f screenshots=true`) and download the
`appstore-screenshots` artifact. That run builds only the screenshots job.

## Sizes

| Set | Size | How |
| --- | --- | --- |
| iPad 13" | 2064 × 2752, portrait | `XCUIScreen` screenshot on the iPad Pro 13-inch simulator (2x of 1032 × 1376 pt). App Store Connect takes the 13" size for every iPad. The script fails if a PNG has another size. |
| Mac | 2880 × 1800 | The Catalyst window (pinned to 1280 × 800 pt) is scaled to fit and centred on a plain 2880 × 1800 canvas with `sips`. A window on a plain background is how Mac shots are usually shown; it avoids depending on the runner's display size. |

The app is iPad-only on iOS (`TARGETED_DEVICE_FAMILY = 2`), so there is no iPhone set. The simulator is
set to light mode and `simctl status_bar override` gives 9:41, full battery and full Wi-Fi (no clutter).
The canvas is always light anyway.

**Mac is best effort.** A Mac UI test needs automation (Accessibility) permission for the test runner
and a window server; the CI job runs it with `continue-on-error`. It has not been run on hardware by the
author of the script (the iPad path was written in a Linux sandbox and verified only by the CI run
named in the pull request), so look at the Mac PNGs before uploading them.

## The shots

| File | Shows |
| --- | --- |
| `01-write` | A lecture note on ruled paper with a margin: headings, a diagram, a highlight; the system tool palette. Full width. |
| `02-sketch` | A design sketch on cream dot paper. Full width. |
| `03-notes` | The note list (all twelve notes: dates, pages, notebook, tag chips) next to the open note. |
| `04-tags` | Sidebar (notebooks, tags) with the `lecture` tag selected, its notes, the open note. |
| `05-paper` | The paper picker over the dot-paper note. |
| `06-unlock` | The key / unlock screen of a locked vault (passphrase or pasted key). |

On the Mac the full-width shots show all three columns instead. Captions are not drawn into the images;
add them in App Store Connect or a design tool. Each shot is a fresh launch whose state comes from launch
variables (below), so the test taps nothing and a layout change cannot break a shot's navigation.

## The demo vault

`DemoVault.swift` builds `My Notes.sempere` in the app's temporary directory on every launch, with a
throwaway post-quantum key, then opens (and unlocks) it. Twelve notes in seven notebooks
(`School/Biology`, `School/Physics`, `School/Spanish`, `Work/Atlas`, `Work/Meetings`, `Personal/Books`,
`Personal/Travel`, plus two outside any notebook), seven tags, six paper styles, one two-page note.
Notes are written through `NoteWriter` like the app's own edits, at fixed dates (the newest is
5 Oct 2026), so the list is the same on every run. The ink is generated: `DemoHandwriting.swift`
lays words out letter by letter from parametric curves (cursive-looking, not legible text), plus ellipses,
boxes, arrows, a star and a padlock, all from a seeded generator (`DemoRandom`, SplitMix64). Nothing comes
from real notes. `DemoVaultTests` pins the structure, the fixed dates and the determinism.

All of it is `#if DEBUG`; release builds contain none of it.

## Launch variables (debug builds)

| Variable | Meaning |
| --- | --- |
| `SEMPERE_DEMO` | Build the demo vault and open it. |
| `SEMPERE_DEMO_LOCKED` | Leave it locked (the unlock screen). |
| `SEMPERE_DEMO_NOTE` | Open the note with this key: `atlas`, `respiration`, `sprint`, `weekly`, `optics`, `quantum`, `photosynthesis`, `lisbon`, `vocabulario`, `books`, `groceries`, `thoughts`. |
| `SEMPERE_DEMO_SIDEBAR` | `all`, `notebook:School/Physics` or `tag:lecture`. |
| `SEMPERE_DEMO_PAPER_PICKER` | Open the paper picker over the note. |
| `SEMPERE_DEMO_MAC_WINDOW` | `WIDTHxHEIGHT` in points (Mac Catalyst). |
| `SEMPERE_DEBUG_COLUMNS` | `all`, `doubleColumn` or `detailOnly` (see `DebugLaunch.swift`). |

## Before uploading

- Look at every PNG. The ink is deliberately not real writing; check nothing reads as a word it should not.
- 1 to 10 screenshots per size; the first three show in search results, so `01-write`, `02-sketch`
  and `03-notes` lead.
- Only features present in the submitted build; no competitor logos, no device bezels.
- If the first shot should be landscape, set `XCUIDevice.shared.orientation` in
  `Apps/Sempere/SempereAppUITests/ScreenshotTests.swift` and expect 2752 × 2064 (change the size check in
  the script).
