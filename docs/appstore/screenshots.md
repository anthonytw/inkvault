# Screenshot shot-list

TODO(user): capture on the Mac with simulators and a real iPad. Use a throwaway demo vault
(not personal notes; never use the git-ignored `data/` backup). Debug launch variables in
`CLAUDE.md` (`INKVAULT_DEBUG_*`, `INKVAULT_DEBUG_SNAPSHOT`) open a vault and note
non-interactively for scripted shots; `simctl io booted screenshot` takes the picture.

## Sizes App Store Connect requires (verify current list in App Store Connect)

- iPad: 13-inch (2064×2752 portrait or 2752×2064 landscape, iPad Pro M4/Air M2 class). 12.9-inch
  (2048×2732) is the older accepted size; one iPad size is usually enough since the app has no
  iPhone build (TODO(user): confirm the app is iPad-only: `TARGETED_DEVICE_FAMILY` in the project).
- Mac (Catalyst): 1280×800, 1440×900, 2560×1600 or 2880×1800.
- 1 to 10 screenshots per size; the first three show in search results. A preview video is optional.

Use landscape on iPad (the natural writing orientation), light appearance (the canvas is always light).

## Shots, in order

1. **Hero: handwriting on the canvas.** A neat page of handwriting with a small diagram, tool
   palette visible, notebook sidebar open. Caption idea: "Write naturally. Encrypted on the page."
2. **Your keys, your notes.** Key screen: generated key with copy/share/back-up actions (only the
   public `age1…` key and a throwaway secret). Caption: "Keys you own. No account."
3. **Sync is a folder.** Vault picker showing "On This Device", iCloud Drive, a folder in Files.
   Caption: "Sync through any folder."
4. **Notebooks and tags.** Sidebar with notebook tree and tag chips, note list with titles and
   dates. Caption: "Notebooks, tags, search."
5. **Search.** Search results highlighting a recognised word (only if recognition ships:
   `docs/plan.md` 3f; otherwise title search).
6. **History.** The history browser / restore point list (only if it ships in the app).
7. **Export.** Share sheet exporting PDF with a vector page behind it. Caption: "Export crisp PDF and SVG."
8. **Readable without the app.** A terminal in the Mac frame showing
   `age -d -i key note.age | tail -c +38 | gunzip | jq .` (composite, plain background).
   Caption: "Open format. Never locked in."
9. **Mac.** The Catalyst window with sidebar, list and canvas side by side (Mac set only).
10. **Privacy.** A plain brand slide: "No account. No server. No tracking." (optional).

Rules: no personal data, no competitor logos (Notability import screens included), no
device bezels Apple does not allow, only features present in the submitted build.
