# Vault I/O

How `Sources/Sempere` reads and writes a vault directory. Not normative:
`docs/format.md` is the format; this records the implementation choices on
top of it.

## Types

- `VaultManifest`: `vault.json` (§2), InkJSON conventions, pretty-printed.
- `BodyFraming`: `SMPR` ‖ `0x01` ‖ tag ‖ `gzip(JSON)` (§4). gzip comes from
  CZlib with `windowBits = 15 + 16`; the gzip header has mtime 0 and OS 255,
  so output does not depend on the platform. Unframing without the vault
  secret returns the body marked `verified == false`.
- `Vault`: a `.sempere` directory plus the identities it was opened with.
  Opened without identities it is locked (`isLocked`) and only lists
  names. Created with `identities: []` it is write-only: it holds the secret
  and can write revisions, but `canRead` is false, read paths throw
  `VaultError.noIdentities`, and `verify()` reports file contents as
  `notChecked`. Note-store
  methods (`write`, `readRevision`, `reconstruct`, `snapshot`, `compact`,
  `history`, `nextSeq`, `verify`) and identity files (`keys/`, §3.2) are
  extensions on it.

## Editing a note

`Vault.apply(_:to:deviceState:app:)` writes one delta of `Op`s as this device:
device id and hybrid clock come from a `DeviceState` file (saved before the
revision is written), the clock first observes every readable revision of the
note so the new ops win LWW, and `seq` comes from `nextSeq`. `NoteOps.newNote`
builds the ops for a new note (one page, all metadata fields, one `addTag` per
tag). Tag edits use `NoteOps.addTag` / `removeTag` / `setTags`, which take the
note's reconstructed state: a `removeTag` lists the instances it observed
(`format.md` §5.4.1); the app's `NoteWriter.append(to:building:)` builds them
from the note as read at write time.

The app does the same with its own `DeviceClock` actor (`NoteWriter.append`
for browser edits, `NoteWriter.write` for canvas autosave), so one process
ticks one in-memory clock over the state file instead of two writers
racing on it.

## Notebook paths

`NotebookPath` and `NotebookNode` (`Notebooks.swift`) implement the `/`
convention of `format.md` §5.4: `components` trims segments and drops empty
ones, `canonical` joins them back, `name(_:isWithin:)` compares whole
segments (`A/Bc` is not in `A/B`), `renamed(_:from:to:)` replaces a path
prefix, and `NotebookNode.tree` builds the sidebar forest with implicit
parent levels. The app renames or moves a notebook as one `setMeta` of
`notebook` per affected note (deleted notes included) and writes canonical
names for new edits; it never rewrites names it does not touch.

## iCloud Drive (app only)

`Sources/` reads a vault with plain `FileManager` calls and stays portable.
On iPadOS, a file iCloud Drive has not downloaded is only a placeholder: a
hidden `.<name>.icloud` stand-in (or, with newer File Provider versions, the
real name with status "not downloaded"). A listing skips the stand-ins, so an
evicted vault looks empty. The app (`Apps/Sempere/SempereApp/CloudVault.swift`,
`CloudScan.swift`, `AppModel+Cloud.swift`) therefore, when the vault folder is
ubiquitous (`FileManager.isUbiquitousItem(at:)`):

1. lists `vault.json`, `rewrap-journal.json`, `keys/*.age` and
   `notes/<id>/*.age`, mapping `.<name>.icloud` to `<name>` (other files are
   not fetched; unknown files are ignored anyway, §1);
2. calls `startDownloadingUbiquitousItem(at:)` on the real URL of every file
   whose `ubiquitousItemDownloadingStatus` is not `.current`;
3. polls (fresh resource values every 0.4 s) until each file that was only a
   placeholder is local, showing "Downloading from iCloud… n/m files" with a
   Cancel button. Files that are local but out of date are requested and
   not waited for. A download error fails the open with the file name; 90 s
   without any file completing fails it with a "check that this iPad is
   online" message. Cancel stops the wait (`CancellationError`, no alert);
4. reads (`Vault.open`, `summaries`, `summary`, `identityFiles`, the
   note an editor opens) inside an `NSFileCoordinator` coordinated read of
   the vault folder, and writes each delta (browser edits and canvas
   autosave, both through `NoteWriter`) inside a coordinated write of its
   `notes/<id>/` folder (vault creation: of the new vault folder), so iCloud
   sees and uploads the new revision files.

Attachments (`notes/<id>/att/`, `format.md` §8.1) are never fetched with
the note: the vault scan, `downloadNote` and `CloudVault.requireLocal` list
only a note's revision files, so an evicted, unlisted or missing `att/`
never makes a note look empty or pending (`docs/attachments.md` §4). When
the canvas shows a page, the `image` and `pdf` blobs its items reference are
requested without waiting (`BlobFetchPolicy`, `AppModel.prefetchBlobs`);
other kinds (audio, video, transcripts) only when used. Drawing an item reads
its blob through the model's `BlobCache` (`AppModel+Attachments`): that one
file is downloaded and awaited (`CloudVault.downloadBlob`), then read inside a
coordinated read that checks it is local (`CloudVault.requireBlob`) and
streamed through the vault's checks into a private temporary file (mode
0600, Data Protection `complete`), least recently used files dropped beyond
512 MB, everything deleted when the vault closes or changes. Meanwhile the
item shows a placeholder with a download symbol. Blobs are written
(`NoteWriter.addBlob`, `copyBlob`) inside the same coordinated write of the
note's folder as deltas. Before a blob is written or copied into a note, that
note's copy of it, if iCloud lists one, is downloaded first
(`NoteEditor.prepareBlobWrite`, `AppModel.blobWritePreparer`): blob names
depend only on the content, so an evicted copy is the same blob and is
reused, never written a second time beside iCloud's placeholder (blob files
are write-once).

Progressive loading: only the small unlocking files (`vault.json`, the
rewrap journal, `keys/`) are awaited before the unlock sheet; the notes are
not. As soon as the vault opens (still locked) `AppModel.startCloudSync`
starts passing over the notes. On iPadOS 26 (measured on 26.7.1) a file
iCloud has not downloaded keeps its real name and is *dataless*:
`ubiquitousItemDownloadingStatus` is "not downloaded", it allocates no
blocks, and no `.icloud` stand-in exists; both forms count as not local. A
note folder that lists no revision file at all is "not listed yet", never an
empty note: every note has at least one revision, and iCloud lists a
folder's contents after the folder itself. The app asks for the folder
(`startDownloadingUbiquitousItem` on it) and waits.

Each pass is change-driven (`AppModel.reconcile`; see "Opening a vault fast"
below): it lists the note folders by name, and only notes whose revision
names differ from those their shown summary was made from are checked with
iCloud (`ProgressiveLoad.pass(notes:)`, one state query per file), sorted
into *ready* (all files local: read at once) and *pending* (some file not
local), and pending ones requested at most 64 notes at a time, the note the
user selected first. A note first seen changed (or reported by the file
presenter) is checked at once; notes already known to be arriving are
re-checked at most 64 per pass, in rotation (`cloudCheckLimit`,
`nextPendingChecks`), so N notes arriving over many passes cost
O(N + passes × 64) state queries, not O(N × passes) (performance round 3: a
mass re-import changed every note of a 640-note vault at once). A note whose files iCloud evicted but whose names are
unchanged is not pending: its row comes from the index and it is downloaded
only when opened (`downloadNote`). While locked, a device that already has an
index of the vault fetches nothing (the index will show which notes changed);
a device opening the vault for the first time requests every note, so they
download while the key is typed.

Pending notes appear in the list with their indexed summary and a small
spinner, or, when nothing is indexed, as "Downloading from iCloud…" rows with
a spinner. A bar under the list shows "Downloading from iCloud: n of m
notes", a progress bar and "n of m files" (`CloudSyncStatus`); it disappears
when no note is pending. While notes are pending the loop re-checks just
those every second (and lists every folder every 15 s); once settled it lists
every folder every 15 s, doubling while nothing changes, at most every 60 s,
for as long as the vault is open, so revisions other devices write arrive
without a pull to refresh. A file presenter on `notes/`
(`NotesFolderPresenter`) wakes the loop early for the notes it names. The
loop pauses while the app is in the background, restarts when the app
becomes active and on every reopen, and a pass of a loop replaced or paused
meanwhile publishes nothing. 90 s without progress shows a problem line in
the bar (not an alert) and the loop keeps trying; the line clears when files
arrive.

Listing (any vault, `AppModel+Loading`): unlocking only checks the key; the
note list is then read by a task the model owns (`startLoadingNotes`), so the
unlock sheet closes at once and no view going away can cancel the listing.
Summaries are read without stroke geometry, on up to four threads, in
batches of 24 (an eighth of the notes, at most 96, when many changed) that are
queued for the list as they finish (applied at most four times a second,
`queueListUpdate`); the bar under the list shows "Opening vault: n of m notes"
(or "Updating 640 changed notes: n done" when the list already shows every
note) next to the iCloud progress. On a reopen the indexed
summaries are shown before anything is read, and only notes whose revision
file names changed are read at all. Listings never overlap (`loadGate`), and
the cache file is written once per listing, not per batch, and while notes
keep arriving from iCloud at most every 20 s (`summaryCacheSaveInterval`;
also when they have all arrived, when the app goes to the background and when
the vault closes): every save re-encrypts the whole index. The list is usable
while it loads, so edits never decide from a summary not read in this session
(`verifiedNoteIDs`: one shown from an earlier launch's cache is re-read
first), a notebook rename waits until every note was read, a batch read
before an edit's own re-read does not merge over it (`summaryEpochs`), and a
listing only removes notes it saw before its scan (a note created meanwhile
stays, and stays selected). An
empty list always says why: loading (with the count), downloading from
iCloud, the listing failed (with Try Again), no search match, nothing in the
selected notebook or tag, or an empty vault (`EmptyListReason`).

Opening a note, and every browser edit of one (rename, tags, move, delete,
restore), first lists that note's folder afresh and downloads whatever is
missing, repeating until a listing shows every revision file local
(`downloadNote`; the detail pane shows "n of m files" meanwhile): a delta
must never be written on top of a partial log, nor computed from a
placeholder's empty summary. The editor's coordinated read checks again,
before and after loading, that every listed file is local
(`CloudVault.requireLocal`): a plain read skips `.icloud` stand-ins and an
unlisted folder reads as a note without pages, which the user would see as
a blank, editable note. Every browser edit's append (`NoteWriter.append`,
which picks the delta's `seq` and observes the note's clock readings) runs
the same check inside its coordinated read and writes nothing when a file
is not local. A note that cannot be made local is shown as an
error with Try Again in the detail pane, never as a blank canvas. Renaming
a notebook waits until no note is pending.

Every reload (pull to refresh) repeats this, so revisions other devices
synced since appear as placeholders, are fetched, and then read. Vaults
outside iCloud skip all of this: no scan, no coordination.

## Opening a vault fast (app)

The note list is shown from a persistent local **index**: the encrypted
per-device summary cache (`SummaryCache`, `format.md` §10) in Application
Support, never in iCloud. It holds each note's summary (title, tags,
notebook, deleted flag, counts, newest time, and whatever `NoteSummary` gains,
such as recognised text for search) and the sorted revision file names it was
made from. On a reopen it is decrypted and shown as it is, before any note
folder is looked at (`openSummaryCache`, `Perf` phase `index.load`).

Keeping it current (`AppModel.reconcile`, `VaultIndex.swift`):

1. **Enumerate by name** (`VaultEnumeration`, phase `reconcile.enumerate`):
   one directory listing per note folder, iCloud placeholders mapped to
   their real names, no file read, no iCloud state asked.
2. **Diff** (`IndexDiff`): revision files are write-once and named by
   `(hlc, device, seq)` (`format.md` §5), so a note whose names equal those
   of its shown summary is unchanged: nothing is downloaded, coordinated or
   decrypted for it. Changed and new notes are read; notes whose folder is
   gone leave the list (only notes listed before the pass, so one created
   meanwhile stays).
3. **Download and read only what changed** (phases `reconcile.download`,
   `reconcile.coordinate`, `reconcile.read`); `indexedNames` records the names
   each summary was made from.

Passes run when the vault opens, when the app becomes active, at the loop's
idle pace and, for the notes named, when the file presenter reports a change.
Every pass waits for the index to be loaded first, so it never mistakes an
unloaded index for a vault where everything changed. A pull to refresh also
re-reads notes the index file does not hold (a summary with a problem).

A **full validation** (`validateVault`, phase `reconcile.validate`) asks
iCloud for the state of every file (slow on a device: one round trip per
file), refreshes out-of-date local copies, reports download errors in the
bar and drops index entries of notes that are gone. It runs at background
priority, outside the listing lock, once the list has settled and then every
30 minutes, and never blocks the list.

**List updates** are batched and throttled: queued summaries are applied at
most every 250 ms (`listUpdateInterval`) as differences (`NoteListDiff`: a
summary whose title order is unchanged is replaced in place, others are
removed and merged in; no re-sort), and `visibleNotes`, `tags` and
`notebookTree` are computed once per change of the list or the filters
(`DerivedLists`), not on every render. An edit's own re-read is applied at
once and supersedes anything queued for that note. The list stays a lazy
SwiftUI `List`.

## Opening a note fast (app)

- **Fast decoding.** A revision's point arrays are parsed by a hand-written
  exact reader (`FastRevisionDecoder`) instead of generic `Codable`
  decoding; the JSON is unchanged and anything unusual goes through the
  ordinary decoder.
- **Drawing cache** (`DrawingCache`, `format.md` §10.1): per note version
  (note id + sorted revision file names) a layout (the note without stroke
  geometry) and each page's PencilKit `dataRepresentation`, sealed under a
  key derived from the vault secret, in `Library/Caches/Sempere/Drawings`.
  Opening a note lists its folder's names; when that version's layout is
  cached the editor opens from it at once (`NoteEditor.isPreparing`: shown,
  not editable) and the shown page's drawing comes from the cache, while the
  revisions are read in the background. Once read, every cached drawing
  shown is checked against the strokes (`DrawingPreparation.matches`: count,
  texture seed from the stroke id, ink, points, ends, transform); a match
  becomes the page's ledger without any conversion, a mismatch is replaced
  by the real page (`canvasGeneration`) before anything can be drawn.
- **On a miss** the page is converted off the main actor, the strokes on
  screen first (`DrawingPreparation.convert(visible:)`, shown as soon as
  they are ready, drawing disabled until the whole page is in), and stored
  in the cache afterwards. Closing a note that was edited stores its new
  version (layout, unchanged pages as shown, changed pages converted in the
  background) and drops the old one.
- The cache is limited to 200 MB (`UserDefaults` key
  `Sempere.drawingCacheMegabytes`), least recently used files first. Opening
  it deletes every other vault's folder (and this vault's under an older
  secret); closing the vault deletes its folder.
- **Attachments** (TestFlight build 6: a PDF note reopened as slowly as it
  first opened). Three caches keep them across note opens and launches, each
  per vault secret and deleted when the vault closes:
  - `BlobCache` (`Library/Caches/Sempere/Blobs`, 512 MB, `Sempere.blobCacheMegabytes`):
    the decrypted, verified blob files PDFKit and ImageIO read. File names are
    keyed (`format.md` §10.1); a file left by an earlier launch is hashed again
    before use (`adopted`), never decrypted again. Not on a Mac: there files
    are not encrypted at rest, so a launch deletes what an earlier one left
    and a reopened PDF is decrypted again (its preview still shows at once).
  - `RenderCache` (`Library/Caches/Sempere/Renders`, 256 MB,
    `Sempere.renderCacheMegabytes`, plus 96 MB of decoded images in memory):
    image items as drawn (`ItemRendering`), and one preview bitmap per PDF page
    item at the unzoomed screen scale. A PDF page shows its preview at once,
    before its blob is opened, and the tile layer draws the sharp page over
    it. Files are sealed like the drawing cache's.
  - The page's tiles themselves are Core Animation's and are not kept: they
    are redrawn from the open PDF at whatever zoom the page is shown, which is
    why the preview, not the tiles, is what persists.

## Performance timing (app)

Every phase above is an `os_signpost` interval (subsystem
`io.github.anthonytw.sempere`, category Points of Interest), in every build:
`vault.open`, `index.load`, `reconcile` (`.enumerate`, `.coordinate`,
`.download`, `.read`, `.validate`), `list.update`, `note.open`,
`note.download`, `note.read`, `note.reconstruct`, `note.cache`,
`note.convert`, `note.firstRender`, `cache.write`, `item.picture` (`hit` or
`drawn`), `pdf.open` (`fetched`, `adopted` or `cached`), `pdf.preview`
(`hit`, `drawn` or `missing`), and `change.notified` events. Comparing a first
open with a reopen: open a PDF note, close the app, launch it again, open the
note: `pdf.open … adopted` and `pdf.preview … hit` lines replace `fetched` and
`drawn`. `AttachmentPersistenceTests` prints `PERF-REPORT pdf-reopen` lines
in the CI `app` log. Debug builds also log each finished interval to the console
(`SemperePerf <phase> <ms> ms <detail>`) and to `Library/Logs/SemperePerf.log`
in the app container (the previous run's as `.1`):

```
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
    --domain-identifier io.github.anthonytw.sempere --source Library/Logs/SemperePerf.log --destination .
```

Details hold counts and 8-hex-digit note id prefixes only. `SEMPERE_PERF_LOG=0`
turns the debug log off; `SEMPERE_DEBUG_DRAWING_CACHE=0` runs without the
drawing cache, for comparisons.

## Saved folder access (sandboxed Mac)

The app opens a vault folder through the system picker and remembers it as a
bookmark (`VaultBookmark`, recent vaults in `VaultLibrary`). Whether a
remembered folder is still usable after a relaunch is the platform's decision:

* **iPadOS:** a bookmark made from a picker URL carries its security scope;
  `startAccessingSecurityScopedResource()` on the resolved URL grants access.
  Verified on devices.
* **Mac Catalyst, not sandboxed:** the app can read what the user can; scope
  calls return false and nothing depends on them.
* **Mac Catalyst, sandboxed (Mac App Store, `Sempere.entitlements`):**
  `.withSecurityScope` is AppKit-only and is not in the Catalyst SDK, so
  bookmarks are made with plain options, as on iOS (`VaultBookmark.make`).
  Apple documents security-scoped bookmarks for sandboxed apps with the
  `com.apple.security.files.bookmarks.app-scope` entitlement (set) and
  `files.user-selected.read-write` (set); whether a plain bookmark of a
  picker URL brings the sandbox extension back after a relaunch under
  Catalyst **has not been verified**: it needs a signed sandboxed build on a
  Mac, which the cloud sessions and CI do not have.

What the code does so that either answer is safe:

* `AppModel.openVault` lists the folder before reading anything
  (`FolderAccess.check`). When the system refuses (`EPERM`/`EACCES`, Cocoa
  257/513, also as an underlying error) it throws `FolderAccess.Problem.noAccess`
  naming the vault folder, instead of a file error from inside `Vault.open`.
* `RootView.reopen` already turns any failure of a recent vault into a message
  and the folder picker, so a lost permission ends with the user choosing the
  folder again, and `remember` saves a fresh bookmark from that scope.
  At launch (`pickOnFailure: false`) only the message shows.
* A stale bookmark is re-saved while its scope is held (`VaultBookmark.resolve`).
* DEBUG builds log `SempereDebug folderAccess scoped=<0|1> listable=<0|1>` for
  every open (no names), to read the answer off a real sandboxed build: after
  choosing a folder and relaunching, `scoped=0 listable=0` means the plain
  bookmark does not survive, and the fix is a Catalyst-only
  `NSURL` bookmark call through an Objective-C shim, which this repository
  does not have.
* The vault's own files under `notes/` are written only through the open
  scope; nothing outside the picked folder is touched. The temporary PDFs of
  drag and drop (`docs/mac.md`) are in the app's container.

## Share and export (app)

The app exports notes through the system share sheet and Save to Files. It
renders with the CLI's renderers: `SempereRender.ShareExport` lays the files
out (the same bytes `sempere export` writes) and `TreeExporter` (moved from the
CLI into `SempereRender`) writes the Markdown and HTML trees.

| Format | One note | Several notes |
| --- | --- | --- |
| PDF | `<stem>.pdf` | one per note, or one merged `Sempere-Notes.pdf` |
| PNG pages | `<stem>-p001.png`, ... | a folder per note |
| Text (Markdown) | `<stem>.md` leading with the recognised text; with the PDF (optional, off) or page PNGs, a folder with them and `README.md` | `Sempere Export/`, mirroring the notebook tree |

`<stem>` is `ExportName.stem` (sanitised title and the first 8 characters of the
note id). Options: paper background (on), PNG resolution (72, 144, 216, 300
dpi), merged PDF, and for text the PDF (off) and page images. The text export
is disabled when no selected note has recognised handwriting. HTML is the
CLI's only (`sempere export --format html`). A one-off share writes no export
manifest.

- **Selection.** "Select" in the note list ticks several notes; a keyboard
  command-click does too. The export commands act on the ticked notes, else the
  open note. `ExportCommand` is the one place that names the actions: the list
  toolbar and context menu, the note toolbar and the Catalyst menu bar
  (`ExportMenuCommands`, File menu) all build from it.
- **Off the main actor, with cancel.** `AppModel.exportNotes` reads each note
  (iCloud notes are downloaded first, reads are coordinated and re-check
  `CloudVault.requireLocal`, so a note missing a revision is reported as a
  failure, never exported stale; same rules as opening a note) and renders in a detached task, checking cancellation between
  notes. `ExportJob` drives it for the export sheet: progress over both phases,
  Cancel, failures listed per note while the others are exported (also in a
  merged PDF, which leaves out a note that cannot be rendered). One export at a
  time: an Export command while the sheet is up is ignored. Closing the
  vault cancels it (generation token). Nothing is written to the vault.
- **Scratch files.** Output is staged under `tmp/SempereExports/<uuid>` (file
  protection "complete" on iOS), deleted when the sheet closes and at every
  launch. A run owns its folder: a run that is cancelled, fails or outlives
  its sheet deletes it when it ends (the note being rendered at that moment
  finishes, and no file is written once the run is cancelled). Share and Save to Files copy from there.
- **Plaintext.** Exports strip nothing and encrypt nothing, exactly like the
  CLI's; the sheet says so. Memory use is that of the CLI: the selected notes'
  states are held at once while rendering.

## Vaults as single items (app)

The app exports the UTType `io.github.anthonytw.sempere.vault` (extension
`sempere`, conforms to `com.apple.package` and `public.directory`;
`Apps/Sempere/SempereInfo.plist`, merged into the generated Info.plist), so
Files shows a vault folder as one document and opening it launches Sempere.
The picker accepts that type and plain folders. `VaultLocator.resolve` turns
what was picked into the vault folder: a folder holding exactly one
`.sempere` resolves to it (several: an error naming them). A file or folder
inside a vault (`vault.json`, `notes/…`) is an error naming the vault: the
access the picker grants covers the picked item and what is below it, never
its parents, so the vault could not be read from it.
New vaults are always created as `<name>.sempere`. Security scope is held on
the URL the user picked. On macOS, Finder shows `.sempere` as a package
(Show Package Contents opens the folder); the CLI and the on-disk layout are
unaffected.

## Atomic writes

Every file the library writes (revisions, `vault.json`, identity files, the
rewrap journal) goes through one helper:

1. write the bytes to `.sempere-tmp-<uuid>` **in the destination directory**
   (same filesystem, so the rename cannot turn into a copy);
2. `fsync` it;
3. `rename(2)` it onto the final name;
4. `fsync` the directory, so the rename itself survives a crash.

A reader or a sync client sees either no file (or the previous version) or
the complete new one, never a partial file. Temp names start with a dot and
lack the `.age` suffix, so every listing ignores them. Deletions (compaction,
the journal) also fsync their directory. Filesystems that cannot fsync a
directory (`EINVAL`, `ENOTSUP`) are accepted (`verify` reports a
leftover as `unknownFile`; nothing deletes it automatically).

**Blobs** (`notes/<id>/att/`, `format.md` §8.1.4) are streamed: the age
file is written chunk by chunk to `.sempere-tmp-<uuid>` in the note's `att/`
(mode 0600) and `fsync`ed, then put in place with `link(2)` onto the final
name, which fails rather than replace an existing file, then the temporary
name is unlinked and the directory `fsync`ed. On file systems without hard
links (FAT, some network shares) it falls back to the existence check and
`rename(2)` above. The only blob that is ever replaced is one whose first
chunk does not decrypt to a valid header for its name (format.md §8.1.4
step 2), or, during a recipient change, a blob rewritten in place or a
damaged file under its new name (§8.1.5). Writers write the blob before the
revision that references it, so a crash leaves an unreferenced blob, never
a dangling reference. `withBlobFile` and `blobs extract --out` decrypt to a
private file that appears (or is handed out) only once the whole content
verified.

Revisions are write-once: `write` refuses an existing name and a reused
`(device, seq)` before renaming. The existence check and the rename are not
one atomic step, but two writers can only race on one name if they share a
device id and sequence number, which the format already rules out.

`nextSeq` takes the largest `seq` seen in file names **and** in any readable
snapshot's `included`, so a device whose old revisions were compacted away
does not reissue a `seq` that a snapshot already claims to cover (which
would make readers drop the new delta).

## Backups

`Backup` (`Sources/Sempere/Backup.swift`) copies a vault's format files
(`vault.json`, `rewrap-journal.json`, `keys/*.key.age`, `notes/<id>/<revision>`,
`notes/<id>/att/<blob>`;
nothing else) with the same atomic-write helper, then reads each copy back
and compares SHA-256. The backup folder is a vault plus `backup.json`
(`format: sempere-backup/1`, `vaultId`, and `files`: path → `sha256`, `size`)
and `versions/<UTC time>/` (previous copies of files a run replaced or, for
the journal, removed). Revisions are copied first and `vault.json` last, so a
run cut short never leaves a manifest newer than its notes; `restore` writes
`vault.json` last for the same reason, behind a `.sempere-restore.json`
marker that lets the same command resume. `backup.json` is saved every 100
files and at the end; a file on disk that it does not list is hashed against
the source before it is trusted. `--prune` uses `CompactionPlanner` with
retention 0 over snapshots present in both the source and the backup (a
pruned snapshot's own coverage is read from the backup's copy), as WebDAV sync
does for deletions. The tar writer is POSIX ustar (names up to 255 bytes via
the prefix field); the archive is verified with a small reader before it is
renamed into place.

## Listing errors

A directory that does not exist lists as empty (sync tools drop empty
directories). Any other listing failure throws `VaultError.io`
(`noteIDs`, `revisionNames`, `identityFiles`, `nextSeq`, the rewrap) or, in
`verify()`, becomes an `unlistable` entry that makes the report unhealthy.
"Could not read" never looks like "nothing there".

`nextSeq(noteId:device:)` throws when a snapshot of the note cannot be read,
since its coverage is unknown. Callers that already hold all revisions use
`Vault.nextSeq(from:device:)`, which reads nothing (`snapshot()` does).

## Recipient changes and resumability (§3.3)

The only in-place rewrite. The procedure is the recommended one of
`format.md` §3.3.1; this section explains the reasoning. Order of operations:

1. Write `rewrap-journal.json` at the vault root; the atomic write fsyncs
   the root directory, so the journal is durable before `vault.json` changes. When the secret rotates
   (recipient removed) it holds the **outgoing** vault secret, age-encrypted
   to the new recipient set.
2. Write `vault.json` with the new recipients and `vaultSecret` (fresh on
   removal).
3. For every revision file: decrypt with our identities, then
   - **skip** it if its header has exactly one stanza of the matching type
     (`X25519` / `mlkem768x25519`) per current recipient (and no other stanzas)
     and its tag verifies under the current secret (already done);
   - otherwise re-encrypt the same plaintext to the new set (on removal,
     first re-tag the unchanged gzip bytes with the new secret, after
     verifying the old tag with the outgoing secret) and replace the file
     atomically.
4. Delete the journal, but only if every file completed. Any failure
   (unreadable file, tag that verifies under neither secret, ...) keeps the
   journal and with it the outgoing secret: deleting it would turn a
   transient I/O error into a permanent tag failure. `pendingRewrap` stays
   true, the report lists the failures, `resumeRewrap()` retries them, and
   no new recipient change starts until it completes
   (`VaultError.rewrapIncomplete`).

If the process dies anywhere, the journal is still there. `Vault.open`
notices it (`pendingRewrap`), keeps the outgoing secret so files not yet
rewrapped still verify (if the journal cannot be read, `open` records why in
`journalProblem`; `verify()` reports it and such files fail as
`tagMismatchJournalUnreadable` instead of a plain tag mismatch), and `resumeRewrap()` (or simply repeating the same
`addRecipient` / `removeRecipient` / `replaceRecipient` call) finishes step 3 and 4. Files that
are already current are skipped, so a run can be repeated any number of
times.

**Blobs in a recipient change** (`Sources/Sempere/BlobRewrap.swift`). After
a note's revisions, each blob in its `att/` is checked from its first chunk
only (stanza counts, and the name against the hash in its header): complete
blobs are skipped. Others are rewritten by the method the journal records
(`rekeyBlobs`, chosen by `RewrapPolicy`): header-only (`AgeFile.rewrapHeader`)
or full re-encryption (`AgeFile.reencrypt`), streaming, with the whole
plaintext checked on the way (framing, zero padding, hash), to a temporary
file. A blob named under the current secret (an addition) replaces itself; one
named under `previousVaultSecret` (a removal) goes to its new name and then the
old name is deleted, and a run that finds a complete copy already under the new
name (a crash between the two) only deletes the old one. A blob whose name
verifies under neither secret, or whose content fails a check, is left as it is
and reported, which keeps the journal. While the journal exists, lookups try
the current name, then the previous one.

Why a stanza count and not "the header lists all recipients": X25519 and
mlkem768x25519 stanzas carry only an ephemeral share or encapsulation, not
the recipient, so a header cannot be matched against public keys. Within one
change the counts differ (n−1 vs n on add, n+1 vs n on remove; X25519 vs
mlkem768x25519 on an X25519 → post-quantum replace), and on removal or
replacement the tag under the new secret also tells old from new (a
replacement within one type changes no count, so the rotated secret is what
marks a file done).

`replaceRecipient` (the post-quantum migration, `format.md` §3.3.2) is a
removal and an addition in one pass. Its pending files are encrypted only to
the outgoing key, so unlike add and remove it cannot be finished by a device
that holds only a key of the new set: resuming needs the old identity too.
The CLI says so, and the old key must be kept until no rewrap is pending. The journal blocks any other recipient change until
it is resolved, so counts from two changes never mix.

A file that verifies under neither secret (tampered or planted) is never
re-tagged: it is left untouched and listed in the report's `failures`, so a
rewrap cannot launder a forged file into a valid one. `verify()` also flags
files whose stanza count differs from the manifest as `staleRecipients`.

## Reading and verification

`readRevision` reports one typed error per stage: `undecryptable` (age),
`tagMismatch`, `corruptBody` (magic, version, gzip), `undecodable` (JSON, or
content naming another note or file name). `reconstruct` and `snapshot`
refuse to proceed past an unreadable revision; `loadNote` returns what is
readable plus the failures. `compact` deletes only names returned by
`CompactionPlanner` over readable revisions, so an unreadable file is never
deleted and never counts as coverage. `verify()` never throws: it re-checks
`vault.json` (format, recipients, the secret's stanza count) and gives every
entry a status.

## WebDAV sync (`Sources/SempereWebDAV`)

The one target with network code. It talks to a plain WebDAV collection that
holds a copy of the vault folder (same layout, `vault.json` at the collection
root) using PROPFIND (Depth 1), GET (with `Range` for blobs), PUT, MKCOL, MOVE and DELETE, so any server
works (Nextcloud, Apache `mod_dav`, nginx dav, rclone serve webdav,
wsgidav). Everything is behind `WebDAVTransport`; `URLSessionTransport` is
the real one (it never follows redirects, so credentials cannot be forwarded
and methods cannot be rewritten) and tests use an in-memory server.

**Security.** Basic auth, `https` only; `http` is accepted for `localhost`,
`127.0.0.1` and `[::1]`. Credentials in the URL are refused. Everything on the
server is already age-encrypted, except `vault.json` (public by design).
A remote `vault.json` with another `vaultId` aborts the run before any
change.

**What is synced.** `vault.json`, `rewrap-journal.json`,
`notes/<uuid>/<name>.age` and each note's attachment blobs
`notes/<uuid>/att/<64 hex>.<kind>.age` (below). Remote entries that are not a lowercase-UUID note
directory, a canonical revision file name (format.md §5), an `att`
collection or a canonical blob name (format.md §8.1.2) are ignored and
listed, never downloaded, so a hostile name cannot escape the vault. `keys/`
and unknown files are not synced. A downloaded revision must start with the
age header or it is rejected. Remote names are reported with control
characters escaped, so a hostile name cannot drive the terminal. Response
bodies are read incrementally and the request is cancelled past a limit
(`maxFileBytes`, 256 MiB, for revisions; 16 MiB for listings, manifests and
everything else), so a server cannot make the client buffer more.

**Write-once files.** For each note the run compares the local and remote file
sets with the set recorded at the last sync (`SyncState.files`):

| local | remote | in last sync | action |
| --- | --- | --- | --- |
| yes | no | no | upload (`If-None-Match: *`) |
| no | yes | no | download |
| yes | no | yes | the server dropped it: delete locally if compaction allows, else upload it again |
| no | yes | yes | we dropped it: delete remotely if compaction allows, else download it again |

An existing file is never overwritten on either side. Downloads go to a
`.sempere-tmp-<uuid>` file in the target directory, are fsynced, and are
linked into place with `link(2)` (fails if the name exists), so a partial file
never appears under its final name and a file that showed up meanwhile wins.

**Compaction deletes.** Sync never decides on its own to delete. A removed file
is deleted on the other side only if `CompactionPlanner.deletable` says so,
with retention 0 (the side that removed it already applied the retention
window) over the revisions held locally: a delta needs a snapshot that covers it,
a snapshot needs one that subsumes it. The covering snapshot must be one the
remote side holds: on the server (as listed at the start of the run) for a file
the server dropped, since a compaction there keeps its covering snapshot there,
and also on the server for a remote delete. An emptied or recreated remote
folder therefore deletes nothing locally; its files are uploaded again. A snapshot removed locally can only be judged from
the `included` coverage recorded when it was last synced. Without an unlocked
vault nothing can be checked, so nothing is deleted. A removal that fails the
check is undone (the file is copied back).

**Attachment blobs** (`docs/attachments.md` §4). Each note's `att/` follows
the same write-once table, keyed `<noteId>/att/<name>` in the state. A note
whose listing has an `att` collection costs one more PROPFIND. Per note,
blobs are transferred before revisions, so a revision does not arrive before
the blobs it references (format.md §8.1.4 step 4) unless a blob transfer
fails: that one is reported and retried by the next run while the note's
revisions still sync, and readers draw a placeholder for it meanwhile
(§8.5.2). Small kinds go first (transcripts, images, PDFs, then the rest), smaller files first.

- *Streaming, own limit.* An upload is a PUT streamed from the file. A
  download is a series of `Range` GETs of 2 MiB (`blobSegmentBytes`), each
  streamed to a partial file, so memory stays bounded by one segment even
  when the server is faster than the disk (on Linux, URLSession queues every
  delivery for its delegate without flow control; with 2 MiB segments the
  resident set stayed near 20 MiB for blobs of 300 MB to 1 GB against a
  local wsgidav). A server that ignores `Range` sends the file in one
  streamed 200, which is still written to disk as it arrives but, on Linux,
  is no longer bounded in memory by the segment size. Blob files have their own limit, `maxBlobBytes` (default
  1 GiB + 64 MiB, `--max-blob-mib`): a larger one is neither uploaded nor
  downloaded, and a body is cut off at the limit whatever the listing said.
  A downloaded blob must have the listed size and start with the age header,
  or it is not written. Its content is verified when read, as for revisions.
- *Write-once on the server.* An upload goes to `att/.sempere-tmp-<uuid>`
  (`If-None-Match: *`) and is renamed with `MOVE` and `Overwrite: F`, so no
  reader sees a partial blob under its name (a server that writes PUT bodies
  in place would show one) and an existing blob is never replaced; losing
  that race is success, since the name is keyed by the content hash. The
  temporary name is recorded in the state before the upload and deleted
  afterwards, or by the next run if this one dies. Other devices' temporary
  names are skipped silently.
- *Resumable.* A download goes to `att/.sempere-tmp-part-<name>` and is linked
  into place (`link(2)`). If the run is cut off, the partial file stays and
  the remote ETag is recorded in the state (saved at once); the next run asks
  for the rest with `Range` and `If-Range: <etag>`, so a blob replaced on the
  server meanwhile comes whole again. A partial file as long as the listing
  says is only checked and placed. A partial file whose blob is no longer
  wanted is removed. Uploads restart from the beginning (WebDAV has no
  standard partial PUT), but only the blob that was cut off. A run killed at
  any request is finished by the next one (`BlobResumeTests`).
- *GC-safe deletes.* A blob one side dropped since the last sync is deleted
  on the other side only if format.md §8.1.6 rules 1–3 hold for its note
  there (the side that dropped it applied rule 4): every local revision of
  the note was read and verified and every revision the server holds is one
  of them (they are byte-identical copies, so both sides' sets were read);
  no `rewrap-journal.json` on either side; and no revision read references a
  content hash whose keyed name is the blob's (any kind). Otherwise the blob
  is copied back. A side with no `att/` at all (a wiped or recreated
  folder) deletes nothing on the other. With the vault locked nothing is
  checked: the blob is neither deleted nor copied back, and is listed as
  skipped.

`sempere-index.json` lists revisions only (`docs/web-viewer.md`), so blobs do
not change it; the run still rewrites the server's copy to list the
revisions the server holds afterwards.

**Mutable files.** `vault.json` and `rewrap-journal.json` are compared by
content hash (SHA-256) against the last-synced hash; the server ETag (or
Last-Modified) is only recorded to send `If-Match` on upload. Local only
changed: PUT with `If-Match`. Remote only changed: atomic replace. Both
changed (or no common ancestor and different content): the remote copy is
saved as `<name>.conflict-<device>-<yyyymmddThhmmssZ>.json` in the vault root
(not again if an identical one exists), nothing else changes, and the
conflict is reported on every run until the files agree. A PUT rejected with
412 is a conflict too. `rewrap-journal.json` deleted locally is not deleted
remotely (deletions come only from compaction) and not restored locally.

**Limits.** A recipient change rewrites files under `notes/` in place
(format.md §3.3), which sync never propagates: after one, pull into a fresh
folder from a new collection (or upload the rewritten vault to a new one) and
retire the old one. `rewrap-journal.json` left on the server by a finished
change is harmless but stays there. Syncing during an unfinished rewrap can
copy a mix of old and new files.

**State.** `$XDG_STATE_HOME/sempere/sync/<hash of URL and vault path>.json`:
file names, hashes, ETags and snapshot coverage, no secrets. Deleting it makes
the next run a first sync: nothing is deleted, nothing overwritten.

**Testing.** `scripts/test-webdav.sh` starts a local wsgidav
(`pip install wsgidav cheroot`) and runs the integration tests, which are
skipped unless `SEMPERE_WEBDAV_TEST_URL` is set.
