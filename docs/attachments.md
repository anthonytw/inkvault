# Attachments: typed text, images, audio, PDF pages

Design, 2026-10-05, revised the same day after the maintainer's review.
Status: **decisions final** (§16), awaiting merge. `docs/format.md` §8 (and
the paragraphs marked *new: attachments* in §1–§7) is the normative part;
this document records why, what was rejected, how each exporter, importer
and app feature should use it, and how the work splits into independent
tasks.

## Contents

1. Scope
2. Storage: per-note blobs
3. Integrity and the blob name
4. Collection (GC), the unused-attachments index, history and sync
5. Placed items and their merge
6. Text boxes
7. Images
8. PDF page backgrounds
9. Audio recordings and transcripts
10. Rendering and export (SempereRender)
11. Notability import
12. Compatibility and versioning
13. Apple-side notes (app tasks)
14. Implementation tasks
15. Settings
16. Decisions

## 1. Scope

In scope: typed text boxes on a page (full Unicode), images, PDF pages as
page backgrounds (annotating PDFs, Notability's 26 PDF notes), audio
recordings with on-device transcripts, and the link between ink and audio
("tap a stroke to hear what was said").

Reserved for later, with names and blob machinery fixed now so that they need
no format change (`format.md` §8.2.7): `math` items (LaTeX equations) and
`video` items. Also later: localization of the app's interface (§14, task L).

Not in scope: typed-text *documents* (reflowing text with ink anchored to
it), arbitrary file attachments, shapes, links, collaboration. The open item
model (§12) lets some of these come later without a format bump.

Constraints carried over from `DESIGN.md` and `CLAUDE.md`: everything at rest
is age-encrypted to the vault recipients and HMAC-bound to the vault secret;
files are write-once; sync tools see only new files; `Sources/` stays pure
Swift on Foundation, swift-crypto and zlib; a user can recover their data
with stock tools. Any future "smart" feature (handwriting to LaTeX, better
transcription) runs on the device only; no AI services.

## 2. Storage: per-note blobs

### Two kinds of data

Attachments mix small, mutable data (where a text box sits, what it says, a
recording's title) with large, immutable bytes (a 3 MB photo, a 40 MB PDF, a
30 MB hour of audio). The first kind belongs in the note log, where it merges
like everything else. The second must not: every snapshot repeats the full
state, so a photo inlined in a revision would be copied into every snapshot
and every restore, and gzip(JSON) of base64 would cost 33 % on top. So large
bytes go into separate encrypted files, *blobs*, that revisions reference by
content hash (`format.md` §8.1.1).

### Layout: `notes/<id>/att/<keyed-hash>.<kind>.age` (decided)

```
Notes.sempere/
  notes/
    <noteId>/
      <hlc>-<device>-<seq>.delta.age
      att/
        3c7e…(64 hex).image.age
        91d0…(64 hex).audio.age
```

Alternatives considered:

| Layout | For | Against |
| --- | --- | --- |
| **`notes/<id>/att/<keyed hash>.<kind>.age`** (decided) | a note is self-contained: its folder holds everything it needs, so copying, backing up, evicting or deleting one note's folder takes its attachments with it; collection reads one note's log, not the vault (§4); the "unused attachments" index updates per note as notes change; the kind lets sync and iCloud fetch images and PDFs on open and audio only on play | no dedupe across notes: the same PDF in three notes is stored three times, and copying an item to another note copies its blob; the kind is visible to storage |
| `blobs/<keyed hash>.age` for the whole vault (first proposal) | one copy of a PDF however many notes use it; one directory to list | collection must read every note of the vault and stops if any one is unreadable; a note's attachments are scattered away from it; no per-note size or eviction |
| fan-out `att/ab/<hash>.age` | small directories | a note holds tens of blobs, not millions; WebDAV would need one PROPFIND per bucket |

Dedupe across notes was the main argument for a vault-wide folder. In
practice the duplicates are few (a re-imported PDF, a Notability "copy" of a
note) and the cost is only storage; in exchange every blob operation is
local to one note, which keeps collection cheap and safe (one unreadable
note cannot block collection of all the others) and makes the
unused-attachments view (§4) a per-note computation.

**The kind suffix.** `image`, `pdf`, `audio`, `transcript`, `video`
(reserved), or `bin`, derived from the reference's media type
(`format.md` §8.1.2). It tells storage which kinds of attachment a note has
(not which note, its title, or the content). In exchange the app and sync
tools can prioritise without decrypting anything: on iCloud, download
`image` and `pdf` blobs when the note opens and `audio` only when it is
played; on WebDAV, sync small kinds first. The size class (padding, below)
already says roughly as much.

**Copying between notes.** Copy-paste of an image to another note, moving an
item to another note, or duplicating a note copies the blob file into the
target note's `att/` before writing the delta that references it. The name
does not depend on the note and the file is encrypted to the vault's
recipients, so a byte copy of the age file is valid; nothing is re-encrypted.

### Framing and padding

The plaintext is a 45-byte header (`INKB`, version, content SHA-256, length)
then the content byte for byte, then zero padding (`format.md` §8.1.3). The
content is stored raw, not gzipped: JPEG, PNG, PDF and AAC are already
compressed, and raw bytes make the stock-tool recovery a `tail | head`.

The header carries the content hash so that a reader can check the blob's
name, and a recipient change can check that a blob is complete, from the
first 64 KiB STREAM chunk alone, without reading a 500 MB file. It carries
the length so that padding can follow the content.

Padding (decided): without it a blob's size gives its content's size to the
byte (age adds a fixed header and 16 bytes per 64 KiB), and the size of a
known PDF or photo identifies it as surely as its hash. Padmé (Nikitin et
al., PETS 2019) rounds to a size class with at most 12 % overhead (about 3 %
at 1 MB) and leaves `O(log log n)` bits of size information. It is a
*should*: readers accept any zero padding, so a writer may skip it. Revision
files are not padded (their sizes say little about content and they are
small).

### Large files

- **Streaming.** age's STREAM payload authenticates 64 KiB chunks, so
  encryption and decryption run in constant memory. `Sources/Age`
  (`Streaming.swift`, task B1) has, next to the one-shot `Data` APIs:
  `AgeEncryptor` (plaintext pieces in, ciphertext out), `AgeDecryptor` (a
  pull iterator over authenticated 64 KiB chunks; the stream is complete
  only when it returns `nil`), file-to-file `AgeFile.encrypt(contentsOf:…)`
  and `decrypt(contentsOf:…)`, `readHeader(contentsOf:)`,
  `rewrapHeader` (header-only rewrite, same file key, nonce and payload,
  every chunk authenticated on the way) and `reencrypt` (new file key and
  nonce). File outputs are created with mode 0600, never overwrite, are
  removed on any thrown failure (so a damaged input never leaves partial
  plaintext; a process killed midway can, so callers decrypt to a temporary
  name and rename it into place) and are fsynced; atomic placement stays with
  the caller (`docs/io.md`). Streaming reads binary age files only (blobs are binary,
  `format.md` §8.1.3). Blobs over 16 MiB must be streamed (`format.md`
  §8.1.4).
- **Random access.** PDF parsing needs it. Readers decrypt the blob into a
  private temporary file (deleted immediately after use; on iOS inside the
  app container, which Data Protection encrypts) and read that. Audio playback
  on iOS reads from the same kind of temporary file (AVPlayer needs a URL).
  Plaintext never goes to a shared or synced location.
- **Size cap.** 1 GiB per blob (`format.md` §8.4): about 35 hours of 64 kbit/s
  AAC, any realistic PDF, a few minutes of 1080p video. WebDAV sync gets a
  separate limit for blobs (currently 256 MiB for everything) and must stream
  GET to a file and PUT from a file instead of holding `Data`.
- **Write order.** Blob first, durable, then the delta that references it
  (`format.md` §8.1.4). A crash in between leaves an unreferenced blob, which
  the unused-attachments index lists and collection removes later; never a
  reference to nothing.

## 3. Integrity and the blob name

Requirement: attachment bytes are bound to the vault secret like revision
bodies, so storage write access does not let anyone plant content.

Revision bodies carry an HMAC tag inside the encrypted plaintext. Doing the
same for blobs has one bad consequence: when a recipient is removed, the
vault secret rotates and every tag must be recomputed, and a tag inside an
age payload can only be changed by re-encrypting the whole payload. That is
acceptable when the payload is re-encrypted anyway (the default on removal,
below), but it would forbid ever choosing a header-only rewrite on removal.

Decided instead: **the name is the tag.** `blobName =
HMAC-SHA256(vaultSecret, "sempere/1" ‖ 0 ‖ "blob" ‖ 0 ‖ sha256(content))`. A
blob is authentic when its content hashes to the value in its header and the
name derived from that hash under the vault secret is its file name; only a
holder of the secret can produce that name. Read through a reference, the
hash must also equal the `sha256` in the referencing revision, which is
itself HMAC-tagged: that is a stronger binding than any tag (exactly this
content, for exactly this item).

The same HMAC keys the name, which answers the second requirement: names must
not leak plaintext content hashes. With plain SHA-256 names anyone with read
access to the storage (the provider, a backup service, a thief with the
iCloud password) could confirm that the vault contains a given file by
hashing it. The keyed name stops that, and padding (§2) stops the same
confirmation by size. What remains visible: per note, the number of blobs,
their kind and size class, their times, and that two notes hold the same
content (equal names in two `att/` folders).

Domain separation: body tags hash `"sempere/1" ‖ 0 ‖ noteId ‖ …` and a
note id is never `blob`, so the two message spaces cannot collide.

Why not bind the note id into the name? It would hide cross-note equality,
but then a copy between notes would need a new name, so a byte copy of the
file would no longer be valid. The note binding that matters comes from the
reference: a blob is only ever looked up from a revision of its own note
(`format.md` §8.1.1), so a blob planted in another note's folder is just an
unreferenced file there.

### Recipient changes

**What "recipients" means.** A vault's recipients are its device keys: one
age key per iPad, Mac or paper backup that may open the vault. "Adding a
recipient" is setting up a new device; "removing a recipient" is locking out
a lost, stolen or retired one. It is not sharing: Sempere has no sharing
between people (`DESIGN.md` non-goals), and giving a note to someone else is
an export (PDF, SVG, PNG), which leaves the vault's recipients alone.

On a removal the vault secret rotates, so names change: the rewrap renames
each blob within its note's `att/` (writes the new name, deletes the old),
with lookups falling back to the previous secret's name while the journal
exists (`format.md` §8.1.5).

**How each blob is rewrapped: decided policy, chosen automatically.**

| Change | Default | Cost for 5 GB of attachments |
| --- | --- | --- |
| add a device key | **header-only rewrite**: new age header wrapping the same file key, nonce and payload copied | one header write and one file copy per blob |
| remove a device key, or move from classic X25519 keys to post-quantum hybrid keys | **full re-encryption** under a new file key | decrypt and encrypt 5 GB |

Why the split:

- *Adding* gives a new device access; every device that could read a blob
  still can, nobody gains anything they did not have. Re-encrypting would
  cost gigabytes of I/O for no security benefit.
- *Removing*: every blob's file key is wrapped, in every old copy of its
  header, to the removed key. Old copies exist outside our control: backups,
  Time Machine, iCloud's version history, the lost device's own cache, an
  old sync folder. If the current file kept the same file key, the removed
  key plus *any* old copy of the header would open the current file and
  every future copy of it. With a new file key, the current files are
  independent of every old copy: the removed key can only read old copies
  that the attacker actually holds in full.
- *Post-quantum migration*: the same argument with "removed key" replaced by
  "a future quantum computer": an old header's classic X25519 stanza stays
  breakable; with the same file key it would open the new, post-quantum
  protected file as well (HANDOFF "Encryption is post-quantum only").

**Settings** (§15): two choices expose these cases, *When adding a device*
(default: rewrite headers only; alternative: re-encrypt everything) and
*When removing a device or upgrading to post-quantum keys* (default:
re-encrypt everything; alternative: rewrite headers only, with a warning
that old copies of the files stay readable to the removed key). The method
in force goes into `rewrap-journal.json` as `rekeyBlobs`, so another device
that finishes an interrupted change uses the same method (`format.md`
§3.3.1). Revisions are small and are always fully re-encrypted, as before.

The header-only rewrite needs a new Age API (B1): unwrap the file key with
an identity, re-wrap it to new recipients, emit a header. Full re-encryption
streams the blob through decrypt and encrypt (B1's streaming APIs). Both are
resumable through the journal.

Note: a recipient change by an *older* build (one that predates blobs)
rewraps revisions only and deletes the journal, leaving blobs encrypted to
the old set and named under the old secret. That is why writers add
`features: ["attachments"]` to `vault.json` (`format.md` §2) and why every
device must run a blob-aware build before the first attachment is written.
Builds from before this change ignore `features` (pre-1.0, no migration);
repair is possible regardless, since a blob's header names its content hash:
decrypt, re-derive the name, rename (task B2's `blobs repair`).

## 4. Collection (GC), the unused-attachments index, history and sync

### When a blob may be deleted

Compaction deletes revisions only when coverage proves nothing is lost. The
blob rule mirrors it, per note (`format.md` §8.1.6): a blob in
`notes/<N>/att/` goes only when every revision of note N was read without
error, no revision of N (snapshot or delta, deleted note or not) references
its hash, and the device saw it unreferenced for at least the retention
window.

- *Per note.* References never cross notes (§2), so only N's log matters. A
  collection run never needs the whole vault, and an unreadable revision in
  one note blocks collection in that note only.
- *Any revision, not just the current state.* A restore point (`format.md`
  §5.7) may show an image that was deleted since. As long as the revision
  that shows it survives, so does the blob; once compaction removes every
  revision referencing it, the blob can go too. History and attachments
  never disagree.
- *All of the note's revisions readable.* An unreadable revision might be
  the only reference (as an unreadable snapshot never counts as coverage).
- *Structural reference test.* Any JSON object with a `sha256` key counts,
  so an older collector keeps blobs referenced by item kinds it does not
  know.
- *Grace window.* Reuse makes collection racy: device B, offline, finds blob
  X in the note's `att/` and writes a delta using it, while A collects X
  because nothing referenced it. The window (device-local "first seen
  unreferenced" times) means B must stay unsynced for 30 days for the race to
  bite. It cannot be closed without coordination, which the format does not
  have. Readers report the dangling reference and draw a placeholder; a
  device that still has the content (the importer, the app that recorded it)
  writes it again.

### The unused-attachments index (app)

The app keeps, in Application Support (device-local, never in the vault), an
index per vault and note: every blob in the note's `att/` with its kind,
size, and the set of revisions that reference it, plus a "first seen
unreferenced" time for each blob no revision references. It is maintained
continuously and cheaply:

- when a note's revisions change (a local write through `NoteWriter`, a
  delta or snapshot arriving by sync, a compaction), the app already decodes
  that note's revisions to rebuild its state; collecting the blob references
  during that decode costs nothing extra, and one listing of the note's
  `att/` finishes the update. Only the changed note is touched: O(revisions
  of that note), never O(vault);
- a blob that becomes referenced again (a late delta from another device)
  loses its "first seen unreferenced" time; the 30-day window restarts if it
  becomes unreferenced again.

Settings (§15) shows **Unused attachments: N items, X MB** from the index,
and a browsable list grouped by note: a preview (thumbnail for images and
PDF pages, duration and title for audio from the last revision that had
them), the note it belongs to with a link to that note's history (the
restore point where it was last used, if any survives), the date it became
unused, and **Delete**. Deletion still honours the safety window: a blob
unreferenced for less than 30 days shows "can be deleted from <date>" and
the button is disabled until then. "Delete all eligible" applies the same
rule to each. A separate line shows space held only by history (blobs that
the current notes no longer show but a surviving restore point does); it
frees itself when compaction drops those revisions after the retention
window.

The CLI's `sempere blobs gc [--dry-run] [NOTE…]` applies the same rule per
note from its own device-local state; collection is never a side effect of
opening, syncing or compacting.

### WebDAV

Each note's `att/` becomes a synced collection with the same write-once table
as revisions (`docs/io.md`): upload with `If-None-Match: *`, download to a
temporary file and `link(2)` into place, never overwrite. The note listing
already shows whether `att/` exists, so only notes with attachments cost one
extra PROPFIND. A blob dropped on one side is deleted on the other only if
`format.md` §8.1.6 rules 1–3 hold for its note there (the side that dropped
it applied rule 4); otherwise it is copied back. Names must match
`<64 hex>.<kind>.age`; a downloaded blob must start with the age header.
Blobs are streamed both ways with their own size limit; small kinds may go
first.

A recipient removal renames every blob, which sync sees as "all blobs
dropped, all new blobs added". As for rewritten revisions, the documented
procedure after a recipient change is a fresh sync from the device that did
it.

### iCloud Drive

Unchanged rules (the app downloads before reading, coordinates writes), with
one difference: a note's `att/` is not downloaded with its revisions. The
vault-open scan and `downloadNote` skip `att/` (a missing or not-yet-listed
`att/` never makes a note look empty or pending, since revisions alone
define the note). When a note opens, the app requests its `image` and `pdf`
blobs that the visible pages reference (`startDownloadingUbiquitousItem`);
`audio` and `video` only when played, transcripts when shown or searched. It
shows a per-item spinner and draws a placeholder until the file arrives.
Evicting blobs is harmless since they never change.

## 5. Placed items and their merge

Text boxes, images and PDF pages are one concept, a *placed item* (`format.md`
§8.2): an id, a kind, a layer, a frame and rotation in page coordinates, an
order key, and kind-specific fields. One shape means one set of ops, one
merge, one selection and move UI, one hit test, one placeholder rule.

### Mutable registers vs immutable items (decided: registers)

Strokes are immutable: editing one is remove + add with `parent`. Doing the
same for items was considered and rejected:

| | LWW registers per field (decided) | Immutable, replace with remove + add |
| --- | --- | --- |
| concurrent moves of one image | last move wins, one image | both survive: two copies of the image |
| move on A, crop on B | both apply (different fields) | two copies |
| concurrent text edits | last edit wins; the other is in history | both versions kept as two boxes |
| ops per drag | one `setItem` | one remove + one add, new id each time |
| item identity | stable for the item's life (good for `rec`, search hits, selection) | changes on every edit |

Duplicated photos after an offline move are a visible, confusing failure;
a lost concurrent text edit is rare for a one-person app and recoverable from
history. Registers follow the existing LWW patterns exactly (`setPageOrder`
with `orderClock`, `setMeta` with `clocks`), so the reducer already has the
machinery. The add/remove side is the stroke rule: set union, removes win,
covered-add removal (a snapshot covering the add but not holding the item has
seen it removed).

Tombstones for items and recordings are permanent, like pages, not pruned
like strokes: a late `setItem` must be distinguishable from one whose
`addItem` has not arrived (orphan, re-applied later, `format.md` §5.3) or the
setter's delta would stay uncovered forever. Items are few (tens per note),
so the cost is nil.

### Layers and z-order (decided: integer layers, ink on top)

Ink is always on top of every item. Items carry an integer `layer`
(`format.md` §8.2.3): `0` is the background layer (PDF pages; drawn with a
paper-coloured fill that hides the ruling under them) and `100` the content
layer (images, text). Items draw by `(layer, z, id)`; within a layer by an
order key `z`, like pages.

Why an integer rather than two names? More layers can be added later
without a format change: a sticker layer at 50, a layer of annotations over
images at 150, or, once the app can split its canvas, layers above the ink.
Old readers already order unknown values by number. Values below 100 are
"background" for the paper fill, so a future layer under the backgrounds
(for example a page template at 10) behaves sensibly in old readers too.

Why not interleave items and strokes freely now? PencilKit draws the whole
drawing in one view; an image between two strokes would need the drawing
split into two canvases. Annotating images and PDFs (writing on top) is the
use case; putting a photo over ink is not. Notability also keeps ink above
media.

Why does a background hide the ruling? Ruled paper over a PDF slide is never
what anyone wants, and many PDFs do not paint their own white page (the
ruling would show through). Images in the content layer do not knock out the
ruling: a transparent PNG on ruled paper shows the ruling, as on paper.

## 6. Text boxes

### Plain or rich (decided: minimal rich text)

Options considered: plain text with one style per box; minimal rich text
(runs with bold, italic, underline, strikethrough, colour, size); full rich
text (fonts, lists, paragraph styles, links).

Decided: **minimal rich text**, a box-level family/size/colour/alignment/
direction plus runs (`format.md` §8.2.4). Bold, a colour and a bigger size
are what handwriting apps' text boxes get used for (headings, labels); lists
can be typed as `•` lines. The whole text is one LWW register, so runs add no
merge complexity.

### Full Unicode (decided)

Text boxes take any script: Latin, Greek, Cyrillic, CJK, Arabic and Hebrew
(right to left), Indic scripts, emoji. The format stores plain Unicode (NFC)
with an optional language tag (`lang`, which matters for CJK: Chinese,
Japanese and Korean share code points but not glyph shapes) and a paragraph
direction (`dir`, default automatic per UAX #9).

**Fonts per platform.**

| Where | Fonts | Coverage |
| --- | --- | --- |
| App (iPad, Mac Catalyst): display and its own exports | system fonts through CoreText: `sans` = the system font (SF Pro), `serif` = New York, `mono` = SF Mono, with CoreText's cascade list for every other script (PingFang, Hiragino, Apple SD Gothic Neo, SF Arabic, SF Hebrew, Kohinoor, Apple Color Emoji, …) | complete: every script iPadOS can display, including CJK, Arabic and Hebrew with correct shaping and right-to-left layout |
| Linux and macOS CLI | bundled **Noto Sans, Noto Serif, Noto Sans Mono** (regular, bold, italic, bold italic where the family has them) | Latin, Greek, Cyrillic |
| CLI, optional | a font pack: any OpenType or TrueType font in `$SEMPERE_FONT_DIR`, `$XDG_DATA_HOME/sempere/fonts` or the system font directories (e.g. Debian's `fonts-noto-cjk`, `fonts-noto-core`), chosen by `cmap` coverage and `lang` | whatever is installed: CJK, Arabic, Hebrew, Devanagari, … |

Noto is under the SIL Open Font License 1.1, which allows bundling and
redistribution. The fonts ship as separate data files under their own
license file, not combined into the program's code, so the OFL and
Sempere's GPL do not interact (as with the fonts every Linux distribution
ships beside GPL software). About 5–6 MB for the Latin/Greek/Cyrillic files.

When the CLI meets a character that no available font covers, it draws the
missing-glyph box for that character only, finishes the export, and reports
it clearly, naming the script and what to install:
`warning: note "Lecture 3", page 2: text uses Han characters; no installed
font covers them (install fonts-noto-cjk or put a font in
~/.local/share/sempere/fonts)`. It never silently ships boxes.

**Exports embed font subsets.** Every exporter embeds, per font it used, a
subset holding exactly the glyphs the export draws (any script), so a PDF
or SVG shows the same glyphs on any viewer, with no missing-glyph boxes and
no dependency on the viewer's fonts. PDF: Type0 / CIDFontType2 (TrueType
outlines) or CIDFontType0C (CFF outlines, e.g. Noto Sans CJK), `ToUnicode`
so text stays searchable and copyable. SVG: an `@font-face` with the subset
as a data URI, `<text>` elements on top so text stays selectable. PNG: glyph
outlines rasterized. Subsetting is required from the start (whole CJK fonts
are 15–20 MB each). In the app, the subset comes from the system font the
text was drawn with (CoreText gives the glyph ids and the font's tables);
embedding subsets of the glyphs used in a document is what every PDF
producer on the platform does.

**Shaping and direction.** CoreText shapes and reorders everything in the
app. The CLI implements UAX #9 (bidirectional reordering per line), UAX #14
(line breaking), grapheme clusters (UAX #29), and a small OpenType shaper:
`cmap`, `hmtx`, GSUB single and ligature substitution for the Arabic joining
features (`isol`, `init`, `medi`, `fina`, `rlig`), and GPOS mark attachment
for Arabic and Hebrew marks (no optional ligatures). Scripts that need a full
shaping engine (Indic conjuncts, Khmer, Myanmar) render unshaped in the CLI
and are reported as approximate; the app's exports of the same note are
exact. A full HarfBuzz port is out of scope (C dependency).

### Keeping layout consistent across renderers (decided: stored breaks)

Different fonts on different platforms have different glyph widths, so the
same text breaks differently unless something is shared. Options considered:

| Option | For | Against |
| --- | --- | --- |
| Same bundled fonts everywhere and one shared layout routine (first proposal) | identical breaks by construction | no complete script coverage without shipping tens of MB of fonts; the app would not look like the system |
| Shared layout from embedded metrics (store or embed the writer's font metrics, every renderer lays out with them) | identical breaks, any font for drawing | the app's system fonts cannot be redistributed or embedded as whole fonts on Linux; metrics of a whole CJK font are large; glyphs drawn with other fonts no longer match the metrics anyway |
| **Fixed vertical metrics plus the writer's line breaks stored in the text** (decided) | identical lines and line positions everywhere, any fonts, a few bytes per box; the app's display and exports are exact | a renderer with wider fonts may overflow a line slightly at its end |
| Fixed vertical metrics only, each renderer breaks by itself (accept differences) | simplest | a label that fits on the iPad can wrap one word earlier in a Linux export, and every following line moves |

Decided: the format fixes everything that can be font-independent, the
vertical metrics (line height `1.2 S`, baseline `0.95 S`) and decoration
positions, so every line sits at the same height on every renderer; and the
writer stores where it broke the lines (`breaks`, offsets in Unicode scalar
values, `format.md` §8.2.4). Renderers cut lines exactly there. Glyph widths
remain the renderer's, so on Linux a line may end a few points earlier or
later than on the iPad; text is never clipped, so a slightly wider line
overflows its frame on its end side instead of moving words to the next
line. Text written without `breaks` (an importer, a CLI that does not lay
out) is broken by each renderer with UAX #14, the only case where line
breaks can differ. `family` records the concrete family the writer used, for
information and for renderers that have the same family.

### Search and recognition

Typed text is exact, so it is searchable as is (CLI `search`, the app's
search) and highlighted with the line boxes of the layout. It is never
copied into `recognition`, which stays derived from ink. PencilKit's Scribble
works in the app's text editor for free (handwriting converted to typed
text as you write in a text box).

### Math (reserved, later)

A `math` item kind is reserved (`format.md` §8.2.7): an equation stored as
LaTeX source, shown typeset, edited as text (tap to edit the source, the
typeset result updates live). The item also stores a rendered PDF of the
result (a blob, `render`), so the CLI and older readers draw it without a
math typesetter. Typesetting runs on device with a Swift math layout library;
candidates, all GPL-compatible:

| Library | Language | License | Notes |
| --- | --- | --- | --- |
| SwiftMath | Swift (CoreText) | MIT | port of iosMath to Swift and SwiftUI; LaTeX math subset; Apple platforms |
| iosMath | Objective-C (CoreText) | MIT | the original; unmaintained but stable |
| MathJax via JavaScriptCore (e.g. LaTeXSwiftUI) | JavaScript | Apache-2.0 (MathJax), MIT (wrapper) | most complete LaTeX; heavier, a JS engine in the app |
| KaTeX via JavaScriptCore | JavaScript | MIT | fast, broad coverage; same JS concern |

Recommendation for the task: SwiftMath first (native, small, MIT), with
MathJax as the fallback if coverage is insufficient. Apache-2.0 is
compatible with GPLv3 (not with GPLv2-only, which Sempere is not).
Handwriting → LaTeX (write an equation, get its source) is a later,
on-device-only feature (a Core ML model; no services); the conversion would
be one delta that removes the strokes and adds the `math` item, so the item
shape needs nothing more for it. Not implemented now (task G1).

## 7. Images

- **Formats.** JPEG and PNG are what every renderer handles: PDF and SVG can
  carry them and a pure-Swift decoder can reasonably decode them. HEIC (the
  iPad camera's default) is converted to JPEG when added unless the user
  turned that off (below); WebP, GIF, TIFF and CMYK JPEG are always
  converted (the app via ImageIO: JPEG quality 0.9 for photos, PNG when the
  source has alpha or is a screenshot). Linux importers that meet another
  format report it dropped.
- **Privacy setting (decided: a setting, on by default).** One setting,
  *Remove location and camera data from photos and convert HEIC to JPEG*,
  on by default (§15). On: writers strip EXIF/XMP/GPS (APPn/COM segments,
  ancillary PNG chunks, HEIC `Exif`/XMP items: `format.md` §8.2.5; lossless,
  segment removal without re-encoding) and convert HEIC to JPEG. Off: the
  photo is stored as picked, metadata and HEIC included (for users who want
  the original file kept). Either way exporters strip location and camera
  metadata from bytes they pass into an export unless an export option asks
  to keep it, because exports are what gets shared. With HEIC stored, the
  app decodes and exports it (ImageIO); the Linux CLI cannot decode HEIC
  (HEVC) and draws a placeholder with a warning naming the item.
- **Orientation** is a field (`orientation`, EXIF 1–8), applied by the
  renderer through the placement transform, so JPEGs are never re-encoded to
  rotate them.
- **Crop** is a register in oriented pixel coordinates; the frame is where
  the crop lands. Rotation is free-angle.
- **Scans.** The document camera produces images; each scanned page can be an
  image item filling a page, or the scan can be saved as a PDF and placed as
  `pdfPage` items. Recommendation: PDF (one blob, one page per scan page,
  background layer `0`).

## 8. PDF page backgrounds

### Item and geometry

A `pdfPage` item is a reference to a PDF blob, a page index, a crop on the
page's *effective* box (CropBox ∩ MediaBox turned by `/Rotate`), and a frame
(`format.md` §8.2.6, §8.5.1). It is an ordinary item, so it can be on a
finite page, in a band of an infinite page, or (in layer `100`) a figure.

### How PDF pages become note pages

The format does not fix this; two layouts, both supported by the same item:

- **Import a PDF (app, CLI `import pdf`).** One note, one finite note page per
  PDF page, each with one `pdfPage` item in the background layer (`0`) whose
  frame fills the page. The note's `pageSize` is the first page's effective
  size, so an exported PDF has the original's page size. Pages of another
  size are fitted (uniform scale, centred) into the note's page size, since
  `pageSize` is per note (a per-page size is a possible later extension).
  Paper is `blank`. A PDF with more than 2 000 pages is refused.
- **Notability import.** One infinite page (as today) with one `pdfPage` per
  PDF page at the band where Notability placed it (§11).
- **Insert pages from a PDF** into an existing note: new pages after the
  current one, same rules as import.

An infinite page grows beyond a background's frame like any other page; a
background crossing a `breakHeight` is cut across export pages like a
stroke.

### Encryption, forms, annotations

PDFs with `/Encrypt` are refused by Linux importers and decrypted by the app
before storing (PDFKit: unlock, then write without a password; owner-password
"restricted" PDFs unlock with the empty user password). Form fields and other
annotations are not drawn; the app may flatten them before storing (PDFKit
can draw annotation appearances into a new page).

## 9. Audio recordings and transcripts

### Recording item

A recording belongs to the note (`format.md` §8.3.1), not to a page:
Notability shows recordings per note, a recording usually spans many pages,
and nothing is drawn for it.

### Codec (decided: AAC-LC default, configurable)

| | AAC-LC in MP4 (`.m4a`) (default) | Opus (Ogg or CAF) |
| --- | --- | --- |
| iPad encoder | hardware, `AVAudioRecorder` default | software; AudioToolbox has it, in CAF |
| playback | AVFoundation, every OS, every player | AVFoundation (CAF), browsers (Ogg); not Preview/QuickTime for Ogg |
| speech at 64 kbit/s mono | transparent | transparent at 24–32 kbit/s |
| size per hour | ~29 MB | ~11–14 MB |
| stock tools | `ffmpeg`, any player | `ffmpeg`, `opusdec` |
| Notability recordings | AAC (to confirm, §11) | |

Default: AAC-LC, mono, 48 kHz (the iPad microphone's native rate, no
resampling), 64 kbit/s. Opus would halve storage, but the savings are small
next to the compatibility cost (stock players, PDF attachment viewers,
Notability import passthrough).

The recording format is **configurable** in Settings (§15), within what
every reader can play, i.e. inside `audio/mp4` (`format.md` §8.3.1):

| Setting | Choices | Default |
| --- | --- | --- |
| Codec | AAC-LC; HE-AAC (better at 24–48 kbit/s); Apple Lossless (ALAC, ~4–6× larger) | AAC-LC |
| Quality (AAC bit rate) | 32, 48, 64, 96, 128 kbit/s (HE-AAC: 24, 32, 48) | 64 kbit/s |
| Sample rate | 48 kHz, 44.1 kHz, 24 kHz, 16 kHz | 48 kHz |
| Channels | mono, stereo (only with a stereo input) | mono |

The panel shows the resulting size per hour. Each recording stores what was
used (`codec`, `sampleRate`, `channels`, `bitRate`), informational only.
Readers must play AAC-LC and should play HE-AAC and ALAC (AVFoundation and
ffmpeg play all three). Other audio types stay allowed so an importer never
has to transcode.

### Video (reserved, later)

A `video` item kind is reserved (`format.md` §8.2.7) and needs no new
machinery: the clip is a blob of kind `video` in the note's `att/`
(`video/mp4` or `video/quicktime`, within the 1 GiB blob cap), placed on the
page like an image with a poster frame (an image blob) that every renderer
can draw. The app plays it with `AVPlayer` from a verified temporary file
(as for audio); PDF exports draw the poster and, in "PDF + attachments",
attach the clip as an embedded file (§10). Not implemented now (task G2).

### Transcripts (decided: separate encrypted JSON)

A transcript is derived data (like `recognition`), replaced as a whole, but
much larger: an hour of speech is about 60 KB of text and 0.5 MB of JSON with
word timings. Inline in the recording it would be copied into every snapshot,
so it is a blob (`format.md` §8.3.2) and the recording's `transcript`
register holds the reference. The transcript names its recording id, so a
transcript blob cannot be attached to another recording. Content is plain
JSON so that `age -d … | tail -c +46 | head -c L | jq .` reads it.

What it holds, explicitly (`format.md` §8.3.2):

- **segments**, time-stamped: `start`, `end` (seconds into the recording),
  `text`, `confidence`;
- optional **per-word timings and confidence** inside each segment: `t`,
  `start`, `end`, `c`;
- the **language** (BCP 47, per transcript and optionally per segment) and
  the **engine and its version** (`apple-speechtranscriber-26.7`).

The word level exists for two features: *read-back highlighting* (while the
recording plays, the current word is highlighted in the transcript, and
tapping a word seeks to it) and *confidence* (doubtful words shown
underlined or greyed, and search that can skip words under a threshold).
SpeechTranscriber gives time ranges and confidence per run, so both are
available on iPadOS 26; SFSpeechRecognizer gives them per segment (its
"segments" are words), which maps to words as well.

Transcription is on device only and opt-in (per recording or per vault).

### Ink and audio sync (decided: `rec` on strokes and items)

In plain words: while you record, every stroke you draw, and every text box
or image you add, is stamped with which recording was running and how many
seconds into it you were (`rec: {id, at}`, `format.md` §5.6, §8.3.3). The
stamp is written once with the stroke and never changes. Later:

- *Tap ink to hear it*: tap a word you wrote and the recording plays from
  the moment you wrote it (from `rec.at`, minus a lead-in of about 2 s, a UI
  choice).
- *Watch the ink as it was written*: during playback, strokes with
  `rec.at` ≤ the current position are drawn normally and later ones faded,
  so the page fills in as the recording plays (Notability's behaviour).
- *Tap a transcript word*: seek to its `start`; strokes written around that
  time can be highlighted.
- *Tap a recognised word*: find the strokes under its box, take the smallest
  `at`, play from there.

Why a stamp on each stroke rather than a list of events in the recording? A
list would grow with every stroke and would have to be merged across
devices; the stamp fits immutable strokes exactly (no extra op), and a
stroke sliced by the eraser passes its stamp to the pieces. The app takes
`at` from `PKStroke.path.creationDate` minus the recording's start date
(both wall clock; PencilKit records stroke creation dates).

## 10. Rendering and export (SempereRender)

### Inputs

Renderers stay pure: they get the note state plus an optional
`BlobSource` (how to get a blob of this note's `att/` as verified bytes, or a
temporary file for large ones), an optional `PDFPageRasterizer` (the app
implements it with PDFKit, the CLI with Poppler, below) and an optional
`TextShaper` (the app implements it with CoreText; the CLI uses SempereRender's
own). Without a blob source every blob-backed item is a placeholder
(`format.md` §8.5.2); text renders regardless. Every exporter returns a list
of placeholders and warnings, which the CLI prints.

### Per item type and exporter

| | PDF | SVG | PNG |
| --- | --- | --- | --- |
| page order | paper, ruling, background items (with paper fill), content items, strokes (`format.md` §8.2.3) | same | same |
| image, JPEG | Image XObject, **DCTDecode passthrough** of the stored bytes; width, height and components from the SOF marker; orientation, crop, frame and rotation as one `cm` matrix; clipped to the frame | `<image href="data:image/jpeg;base64,…">` with the same matrix in `transform` and a `clipPath`; `--assets DIR` writes files and links them instead | decoded (baseline and progressive JPEG decoder), resampled (bilinear up, area average down) through the inverse placement transform |
| image, PNG | decoded, re-encoded FlateDecode 8-bit RGB or Gray, alpha as `/SMask`; 16-bit reduced to 8; palette expanded | passthrough data URI | decoded |
| PDF page | **Form XObject** imported from the source PDF (below), always, on every platform; one XObject per (blob, page) per export, shared resources copied once | a PNG from the `PDFPageRasterizer` (PDFKit in the app, Poppler in the CLI when installed), else placeholder plus warning | rasterizer output, else placeholder plus warning |
| text | **font subsets** embedded (Type0: CIDFontType2 for TrueType outlines, CIDFontType0C for CFF; Identity-H; `ToUnicode` so text is searchable and copyable), glyphs positioned per the layout of `format.md` §8.5.3 | `@font-face` with the subset as a data URI; `<text>` per line with `<tspan>` runs at the layout's positions, `xml:space="preserve"`, `direction` for RTL | glyph outlines (`glyf` or CFF), filled with the existing scanline rasterizer |
| recording | not on pages; see below | omitted | omitted |
| unknown kind, missing blob | placeholder | placeholder | placeholder |

Matrices: the content stream starts with `1 0 0 -1 0 H cm` (y down). An image
XObject paints the unit square with y up; a form paints its BBox in PDF user
space. The exporter composes, per item: source → effective/oriented
coordinates (`format.md` §8.5.1 tables) → crop to frame → rotation about the
frame centre, and emits it as one `cm` after `q`, with the frame (rotated)
as clip path (`W n`).

### PDF backgrounds in SVG and PNG

PDF export never needs to render a PDF page: it embeds the original page as
a Form XObject (below), so it is exact on every platform. SVG and PNG need
pixels (or vectors) of the page, which needs a full PDF renderer, far beyond
the minimal reader. So:

- **Apple platforms:** the app's `PDFPageRasterizer` draws with PDFKit
  (`CGPDFPage`).
- **Linux and macOS CLI:** an optional external renderer. If Poppler's
  `pdftoppm` (or `pdftocairo`) is on `PATH` (or named by
  `SEMPERE_PDFTOPPM`), the CLI's rasterizer runs it as a separate process
  on the verified temporary plaintext of the PDF blob, e.g. `pdftoppm -png
  -r DPI -f N -l N -singlefile TMP.pdf OUT` with the effective-page crop,
  and places the PNG through the usual placement transform (SVG embeds it as
  a data URI, PNG composites it). It is invoked with an argument vector,
  never a shell, with a timeout and an output size limit; the temporary
  files are private and deleted afterwards. Running the PDF parser in
  another process also isolates the CLI from a hostile PDF. Poppler is
  GPL-2.0-or-later; it is not linked, only executed, so it adds no license
  terms to Sempere (and is GPL-compatible anyway). `Process` exists on
  macOS and Linux but not iOS, so the rasterizer lives in
  `Sources/SempereCLI`, not in `SempereRender`. `--pdf-renderer auto|poppler|none`
  selects it; `auto` is the default.
- **No renderer available:** the page is a placeholder (`format.md`
  §8.5.2) and the export prints a clear warning:
  `warning: 12 PDF background pages drawn as placeholders: install poppler
  (pdftoppm) to render them, or export as PDF, which keeps them exactly`.

### Minimal PDF reader (for Form XObjects and page boxes)

A new Linux-portable target `SemperePDF` (Foundation + CZlib), used by SempereRender
(export) and SempereImport (page boxes, page count). Subset:

- File structure: header, `startxref` from the last 1 KiB, classic xref
  tables and trailers, xref streams (`/Type /XRef`, `/W`, `/Index`, Flate
  with PNG predictors 10–15), hybrid files (`/XRefStm`), incremental updates
  (`/Prev` chain, newest wins), object streams (`/Type /ObjStm`). If the xref
  is broken, rebuild it by scanning for `n g obj` (real-world PDFs often need
  this).
- Lexer: all object types (null, booleans, integers, reals, literal strings
  with escapes and balanced parentheses, hex strings, names with `#xx`,
  arrays, dictionaries, indirect references, streams with direct or
  indirect `/Length`, `/Length` wrong → scan for `endstream`).
- Page tree: `/Pages` → `/Kids` with inherited `/Resources`, `/MediaBox`,
  `/CropBox`, `/Rotate`; cycle detection, depth ≤ 64.
- Filters, decoding only where needed: FlateDecode (with predictors) for
  xref and object streams and for content streams; content streams in other
  filters (LZW, ASCII85, ASCIIHex, RunLength) are decoded too (all short); a
  content stream with a filter not in this list fails the item (placeholder
  plus warning, or the app's rasterizer). Every other stream (fonts, images
  in DCT, JPX, JBIG2, CCITT) is copied with its filter untouched, never
  decoded.
- Copying a page as a form: the page's content streams decoded and
  concatenated (separated by a newline), re-compressed with Flate;
  `/Resources` deep-copied with every reachable indirect object renumbered
  into the output (one copy per source object per export); `/BBox` = the
  visible box; the page's `/Group` (transparency group) carried to the form.
  Not copied: `/Annots`, `/Parent`, `/StructParents`, `/Metadata`,
  `/PieceInfo`, `/Thumb`, `/B`.
- Refused: `/Encrypt` present. Limits: 10⁶ objects, 256 MiB per decoded
  stream, nesting depth 64, each enforced with an error, never a crash
  (fuzzed in tests).
- Output: `PDFWriter` switches to `%PDF-1.7` when it embeds forms (copied
  objects may use 1.5+ features such as JPX).

### Text, fonts and the PDF writer

Exports embed **subsets** from the start: whole fonts are too large (a CJK
font is 15–20 MB) and system fonts may only be embedded as subsets. A
subset keeps the glyphs the export draws (plus `.notdef`), renumbered, with
`glyf`/`loca` or the CFF charstrings rewritten, `hmtx` trimmed, and a
`ToUnicode` CMap built from the shaped runs (so ligatures and Arabic forms
still copy as the original characters). Subset font names get the usual
six-letter tag (`ABCDEF+NotoSans-Regular`). In the CLI the glyph ids and
advances come from SempereRender's shaper (§6); in the app from CoreText through
the `TextShaper` hook, which also hands over the font's tables
(`CTFontCopyTable`) for subsetting. Bold and italic use the family's faces;
synthesised ones (`format.md` §8.5.3) use an outline stroke or a `Tm` shear
(12°).

*Implementation notes (C2, CLI):* the shaper also applies GSUB multiple and
(chained) context substitution, which Arabic fonts such as Noto Naskh use for
lam-alef, and runs features in HarfBuzz's stage order; its output matches
HarfBuzz on the test strings. SVG text addresses glyphs through private-use code
points of the subset's `cmap` (a viewer would otherwise reshape the text with a
subset that has no layout tables), with an invisible `<text>` per line carrying
the real characters for selection and search.

### Audio in exports

Pages never show recordings. Options for the PDF (decided):

- default: nothing; the export report says "2 recordings not exported";
- app: the export sheet has **PDF** and, next to it, **PDF + attachments**,
  which embeds every recording (and its transcript as a `.txt`) as a PDF
  file attachment (`/Names /EmbeddedFiles`, PDF 1.4). Preview, Acrobat and
  most viewers list them and let the user save or play them;
- CLI `--recordings attach`: the same embedded files;
- CLI `--recordings list`: an appended page listing each recording's
  title, start time, duration and its transcript text (when there is one);
  `--recordings list,attach` does both.

SVG and PNG exports omit recordings. A separate `sempere export --format
media` writes the note's original blobs (images, PDFs, audio, transcripts) as
files, named `<title>-<n>.<ext>`.

### Raster limits

Images over 100 megapixels are drawn as placeholders (`format.md` §8.4).
Decoders stop at the image's declared size and at truncated input; JPEG
decoding uses DCT scaling (1/2, 1/4, 1/8) when the output needs fewer pixels,
so a 12 MP photo in a small frame never decodes at full size.

## 11. Notability import

From `docs/import-notability.md` (what is known) and what the importer
drops today (`Dropped`). Every mapping below keeps the existing geometry
(document units × `612 / W`, the 18.8-unit x inset, one infinite page with
`breakHeight`).

### PDF backgrounds (26 of 130 sample notes)

- `richText.pdfFiles` → one blob per `PDFs/<pdfFileName>` (type
  `application/pdf`) in the note's `att/`, deduplicated by content within
  the note.
- `richText.pageLayoutArray` → one `pdfPage` item per entry, in the
  background layer (`0`): `pageIndex = kPageLayoutPDFPageNumberKey − 1` (to
  confirm whether it is 0- or 1-based), blob from `kPageLayoutPDFFileNameKey`,
  frame `[0, y, 612, 612 · H'/W']` at
  `y = (kPageLayoutDocumentPageNumberKey − 1) · stride`, where `stride` is the
  page height the importer already computes (`⌈W × aspect⌉ × 612 / W`), and
  `W' × H'` the effective page size read with `SemperePDF` (it replaces the
  thumbnail-derived aspect when available, which fixes the mixed-size case).
  `z` follows the page order.
- Paper under PDF pages: the note keeps its paper; the backgrounds hide its
  ruling (`format.md` §8.2.3).
- `TemplatePDF:<uuid>` paper: a PDF used as paper on every page. Map to one
  `pdfPage` per band, all referencing the template's blob (one blob in the
  note, however many bands), once the template's location in the package is
  known.
- `PDFFile.highlights` were always empty; if found non-empty, they are
  highlights on the PDF (map to marker strokes).
- Acceptance: the 15 ink-less PDF notes import with their pages; the eval
  report's `pdf-template` flags disappear; the oracle compares against the
  thumbnail with the PDF drawn (export with pdfium in the eval scripts).

### Images (4 sample notes)

- `richText.mediaObjects` entries of class `ImageMediaObject` → `image`
  items in the content layer (`100`). Bytes from `Images/` or `Assets/`;
  JPEG and PNG are stored (metadata stripped by default, as for the app's
  photo setting); HEIC is stored as is when the CLI cannot convert it (the
  app's import path converts it); other formats are reported dropped.
- Frame, rotation, crop: from the media object's fields (unknown, below);
  position in the same document coordinates as ink, then scaled.

### Typed text

- `richText.attributedString` is Notability's flowing typed text (the samples
  hold only newlines). Map non-blank text to one `text` item per paragraph
  block at the top of the page (any script; written without `breaks`, so
  renderers break its lines), frame width = page width minus Notability's
  text margins (unknown), runs from the attributed string's attributes:
  `NSFont` → family (`Helvetica*`/`SF*`/`Avenir*` → `sans`, `Times*`/
  `Georgia*` → `serif`, `Courier*`/`Menlo*` → `mono`) plus bold/italic from
  the font name, point size × `612 / W`; `NSColor` → `color`; underline and
  strikethrough attributes.
- Text boxes (if Notability stores them as media objects, not in the
  attributed string): one `text` item each.
- Notability reflows ink with typed text (`NBReflowStateReflowable`); the
  import pins text and ink where they were laid out at import time.

### Recordings

- `Recordings/library.plist` (`recordings` dictionary) → one recording per
  entry: blob from the audio file (passthrough: AAC in MP4 or CAF stored as
  is with its media type; `audio/x-caf` is playable by AVFoundation), title,
  start date, duration.
- `eventTokens` (4 bytes per curve, `ffffffff` when none, older formats):
  presumed to map a curve to a playback event; map to the stroke's `rec`
  once decoded. Newer formats (8–9) must store sync elsewhere.
- Notability's own transcripts, if any (newer versions transcribe), map to
  transcript blobs with `engine: notability-<version>`.

### Unknowns to investigate (with the user's backup, never committing it)

1. `ImageMediaObject` (and other `mediaObjects` classes): field names for
   frame, rotation, crop, z-order, file reference; are they in document
   units with the 18.8 inset?
2. Text: where text boxes live (`mediaObjects` class?) vs
   `attributedString`; Notability's text margins and default font.
3. `kPageLayoutPDFPageNumberKey`: 0- or 1-based; meaning of
   `kPageLayoutPDFIsOriginalPageKey` (inserted blank pages?).
4. Notes mixing PDF pages of different sizes: is the stride per page or
   per note?
5. Template PDFs (`TemplatePDF:<uuid>`): where the PDF is stored.
6. `Recordings/library.plist` layout, audio container and codec, start
   times, durations; multiple recordings per note.
7. `eventTokens` encoding and the audio-ink sync of formats 8–9.
8. Whether any PDF in the backup is encrypted, and whether any has
   annotations Notability drew (would need flattening).
9. `NBPDFIndex/`: Notability's PDF text index (could seed search of PDF
   text; out of scope here).

## 12. Compatibility and versioning

`format.md` §7 says readers reject a revision holding an unknown op (fail
closed). That stays right for ops: an op type carries merge semantics, and a
reader that dropped it and then wrote a snapshot claiming to include the
delta would lose the op for every device forever.

Item kinds are different. Every item merges the same way whatever its kind
(set of ids, LWW registers), and a placeholder in its frame is a faithful
degraded rendering. So inside item and recording ops the format is open
(`format.md` §7): unknown kinds and fields are kept, merged generically and
re-emitted unchanged in snapshots; unknown setItem fields are registers;
unknown layer numbers are ordered by value. This is what lets `math` and
`video` (reserved, `format.md` §8.2.7), and later `shape` or `link` items,
arrive without making every note that uses them unreadable on an older iPad.
Costs:

- the core model must keep the raw JSON of unknown fields
  (`[String: JSONValue]` beside the typed fields) and re-encode it verbatim;
- collection must find blob references structurally (`format.md` §8.1.1);
- placeholders must exist in every renderer and in the app.

Strokes and pages stay closed (their unknown fields are dropped by today's
readers); `rec` on strokes is new and is lost if an older build rewrites
a stroke into a snapshot. Pre-1.0 this is acceptable: all devices update
before the first recording.

Versioning: `format` stays `sempere/1` and the body version byte `0x01`
(pre-1.0, `format.md` §7). Today's builds reject revisions with the new ops
(fail closed, reported), skip `att/` when listing revisions (it is a
directory, not a canonical revision name) and report it as an unknown entry
in `verify`: they cannot show notes with attachments but cannot damage them,
except through a recipient change (§3 above). New: `vault.json` `features`,
the general mechanism for "older writers must stay read-only", starting with
`attachments`.

## 13. Apple-side notes (app tasks)

Guidance for the app tasks, not normative. Deployment target iPadOS 26; the
user's iPad is a 2020 iPad Pro (A12Z) on 26.7.1 and cannot run 27, so every
API below must be checked on 26 and, where marked, on that device.

### Writing attachments

All vault writes go through `NoteWriter` (CLAUDE.md). It gains
`addBlob(note:from:type:) async throws -> BlobRef` (streams through
`Vault.writeBlob` into that note's `att/`, inside the same coordinated write
as the delta in iCloud Drive) and `copyBlob(_:from:to:)` for copy and paste
between notes, used before the delta that references the blob. Picked files
and recordings are copied into the app container first (security-scoped URLs
expire). Every `NoteWriter` write also updates the unused-attachments index
for its note (§4).

### Audio recording

- `AVAudioRecorder` with the settings from the recording panel (§9, §15):
  default `AVFormatIDKey: kAudioFormatMPEG4AAC`, `AVSampleRateKey: 48000`,
  `AVNumberOfChannelsKey: 1`, `AVEncoderBitRateKey: 64000`
  (`kAudioFormatMPEG4AAC_HE` and `kAudioFormatAppleLossless` for the other
  codecs), writing an `.m4a` in the app's temporary directory; on stop,
  `NoteWriter.addBlob` then `addRecording`. Simple and robust; transcription
  runs after the recording ends.
- `AVAudioEngine` (input node tap → `AVAudioFile` with the same settings, and
  the same buffers fed to `SpeechAnalyzer`) is the route to a live
  transcript; more moving parts (format conversion, interruptions). Do it
  second.
- `AVAudioSession`: `.playAndRecord`, mode `.default` (`.spokenAudio` for
  playback), options `.allowBluetoothHFP`/`.defaultToSpeaker`; handle
  interruptions (calls, Siri) and route changes by pausing and appending.
  `UIBackgroundModes: audio` to keep recording with the screen locked or the
  app in the background; microphone usage string in `Info.plist`.
- Long recordings: keep the file on disk, never in memory; a 3-hour lecture
  is about 86 MB at the default. If the app is killed mid-recording, the
  `.m4a` is not finalised; record in segments (for example a new file every
  10 minutes, stitched as several recordings or concatenated with
  `AVMutableComposition` on stop) so that a crash loses at most one segment.
- `rec.at` for strokes: `PKStroke.path.creationDate − recordingStart`.

### Transcription (on device only)

- Preferred on iPadOS 26: `SpeechAnalyzer` with `SpeechTranscriber`
  (Speech framework, new in 26): file input
  (`analyzeSequence(from: AVAudioFile)`), long-form, word-level time ranges
  (`attributeOptions: [.audioTimeRange]`) and confidence
  (`.transcriptionConfidence`). Model assets come from `AssetInventory`
  (`assetInstallationRequest(supporting:)`); check
  `SpeechTranscriber.supportedLocales` / `installedLocales` and
  `isAvailable` at run time. Device support on the A12Z is **unverified**:
  test on the user's iPad before building UI around it.
- Fallback 1: `DictationTranscriber` (same `SpeechAnalyzer` API, the
  dictation model, broader device support, less accurate for long-form).
- Fallback 2: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
  (only if `supportsOnDeviceRecognition` for the locale) and an
  `SFSpeechURLRecognitionRequest`; word timestamps and confidence from
  `SFTranscriptionSegment`. Never server recognition (no network, `DESIGN.md`).
- Opt-in per recording or per vault; show progress; write the transcript
  blob (segments, words with timings and confidence, language, engine), then
  `setRecording(transcript:)`. `engine` e.g. `apple-speechtranscriber-26.7`,
  `apple-sfspeech-26.7`.
- Permissions: `NSSpeechRecognitionUsageDescription` (needed for
  `SFSpeechRecognizer`; check whether `SpeechTranscriber` needs it).

### Images

- `PhotosPicker` (`PhotosUI`) → `loadTransferable(type: Data.self)` (often
  HEIC) → with the privacy setting on (default), ImageIO (`CGImageSource`,
  `CGImageDestination`) to JPEG q 0.9 or PNG with metadata dropped; off, the
  picked bytes as they are. Orientation is read from the source properties
  into the item either way. Drag and drop and paste (`UIPasteboard`) take
  the same path.
- Camera: `UIImagePickerController(.camera)` wrapped in SwiftUI; document
  scanning: VisionKit `VNDocumentCameraViewController` → a PDF
  (`PDFDocument` from the scan images) → `pdfPage` items.
- Display: decode with `CGImageSourceCreateThumbnailAtIndex` at the needed
  pixel size (never full-size for a small frame), cache per zoom level.

### PDF import and display

- `.fileImporter(allowedContentTypes: [.pdf])` → copy into the container →
  `PDFDocument`; if `isEncrypted`, try `unlock(withPassword: "")`, else ask;
  write an unencrypted copy with `write(to:withOptions:)` without password
  options (verify the output has no `/Encrypt`) and store that; otherwise
  store the original bytes unchanged.
- Page geometry: `PDFPage.bounds(for: .cropBox)` and `rotation` give the
  effective size; must agree with `SemperePDF` (test both on fixtures).
- Display under `PKCanvasView`: a background view between `PaperView` and
  the canvas, drawing each visible `pdfPage` item with
  `CGContext.drawPDFPage` in a `CATiledLayer` (sharp at 4× zoom without
  holding full-resolution bitmaps); memory bounded by the tile cache.
- `PDFPageRasterizer` for the app's SVG/PNG export, implemented with PDFKit
  (`CGPDFPage` drawing).

### Text editing on the canvas

- A text tool: a `PKToolPickerCustomItem` in the system tool picker
  (iPadOS 18+; build it alongside `EraserPreference`'s items) or a separate
  toolbar control. Tap to create a box; a `UITextView` overlay at the frame
  (converted through the canvas zoom and offset) with the system fonts of
  §6. While editing, the canvas's drawing gesture is disabled; Scribble works
  inside the text view; the keyboard's language gives the box's `lang`.
- On end of editing: `addItem` (new) or `setItem(text)` with `breaks` taken
  from the text view's layout (TextKit 2 line fragments, converted to
  Unicode scalar offsets); empty new box → no op. Debounce like strokes (one
  delta per pause).
- Committed text drawn with CoreText at the format's fixed vertical metrics
  (`format.md` §8.5.3) and the stored breaks, so display and the app's
  exports are identical.
- Selection, move, resize, rotate, delete for all items: a custom overlay
  (PencilKit's lasso selects strokes only). One `setItem(frame)` per
  gesture end, not per frame. Copy, cut and paste of items across notes
  copy their blobs (`NoteWriter.copyBlob`).

### Export options

The export sheet offers **PDF** and **PDF + attachments** side by side (plus
SVG and PNG). "PDF + attachments" embeds the note's recordings (and their
transcripts as `.txt`) as PDF file attachments (§10); plain PDF leaves them
out and says so in a footnote line of the sheet ("2 recordings not
included").

## 14. Implementation tasks

Each task is one branch, one PR, CI green, and updates the docs it touches
(`docs/io.md`, `docs/cli.md`, `docs/import-notability.md`, `docs/plan.md`).
Task **A0** is small and goes first: it defines the model types every other
task compiles against. After A0 merges, everything else can run in
parallel; the dependency notes say what to stub meanwhile. Tasks G1, G2 and
L are future work, listed so that they are not forgotten; they do not block
anything.

API sketch (A0 and B2 own these names; others code against them):

```swift
// Sempere (A0)
public enum JSONValue: Hashable, Sendable, Codable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }
public struct Rect: Hashable, Sendable, Codable { var x, y, w, h: Double }                         // [x, y, w, h]
public struct Size: Hashable, Sendable, Codable { var w, h: Double }                              // [w, h]
public struct BlobKind: RawRepresentable, Hashable, Sendable { static let image, pdf, audio, video, transcript, bin; init(mediaType:) }  // open set
public struct BlobRef: Hashable, Sendable, Codable { var sha256: String; var size: Int64; var type: String; var extra: [String: JSONValue]; var kind: BlobKind { get }; var digest: Data? { get } }  // kind per format.md §8.1.2
public struct RecordingLink: Hashable, Sendable, Codable { var id: UUID; var at: Double }        // "rec"
public struct TextRun: Hashable, Sendable, Codable { var t: String; var b, i, u, s: Bool; var color: Color?; var size: Double?; var lang: String?; var extra: [String: JSONValue] }
public struct TextContent: Hashable, Sendable, Codable { var font: Font; var family: String?; var size: Double; var color: Color; var align: Alignment?; var dir: Direction?; var lang: String?; var runs: [TextRun]; var breaks: [Int]?; var extra: [String: JSONValue]; var string: String; var validBreaks: [Int]? }  // Font/Alignment/Direction: open sets with `.effective`
public struct ItemKind: RawRepresentable, Hashable, Sendable, Codable { static let text, image, pdfPage; static let math, video /* reserved */ }   // open set
public struct ItemLayer: RawRepresentable, Hashable, Sendable, Codable, Comparable { var rawValue: Int; static let background = 0, content = 100 }  // open set
public struct Item: Hashable, Sendable, Codable, Identifiable {
    var id: UUID; var kind: ItemKind; var layer: ItemLayer; var frame: Rect; var rotation: Double?; var z: String
    var parent: UUID?; var rec: RecordingLink?; var origin: String?; var clocks: [String: String]?
    var text: TextContent?; var blob: BlobRef?; var pixelSize: Size?; var orientation: Int?
    var crop: Rect?; var pageIndex: Int?; var pageSize: Size?   // read only for the kind that has them
    var extra: [String: JSONValue]   // unknown fields (all non-common ones for an unknown kind), re-emitted verbatim
    static func drawsBefore(_:_:) -> Bool                        // (layer, z, id)
}
public struct Recording: Hashable, Sendable, Codable, Identifiable { /* format.md §8.3.1, plus extra; static func sortsBefore */ }
public struct Transcript: Hashable, Sendable, Codable { /* format.md §8.3.2; static func decode(Data) (64 MiB, validated), func encoded() */ }
// Page.items: [Item]; NoteState.recordings: [Recording]; Tombstones.items, .recordings; Stroke.rec
// Op: .addItem(page:item:), .removeItem(page:itemId:), .setItem(page:itemId:change: ItemChange),
//     .addRecording(Recording), .removeRecording(recordingId:), .setRecording(recordingId:change: RecordingChange)
// ItemChange: .frame(Rect), .rotation(Double?), .z(String), .text(TextContent), .crop(Rect?), .other(field:value: JSONValue)
// RecordingChange: .title(String?), .transcript(BlobRef?), .other(field:value:)
//     both: `field`, `init(field: String, value: JSONValue) throws ItemChangeError` (immutable field, null rules, types)

// Sempere (B2)
public enum RewrapMethod: Sendable { case headerOnly, reencrypt }
public struct RewrapPolicy: Sendable { var onAdd: RewrapMethod = .headerOnly; var onRemoveOrTypeChange: RewrapMethod = .reencrypt }
extension Vault {
    public func blobName(sha256: Data) throws -> String
    public func writeBlob(note: UUID, contentsOf file: URL, type: String) throws -> BlobRef   // streaming
    public func writeBlob(note: UUID, _ data: Data, type: String) throws -> BlobRef
    public func copyBlob(_ ref: BlobRef, from: UUID, to: UUID) throws
    public func readBlob(note: UUID, _ ref: BlobRef, maxBytes: Int) throws -> Data            // verified
    public func withBlobFile<T>(note: UUID, _ ref: BlobRef, _ body: (URL) throws -> T) throws -> T  // verified temp plaintext
    public func blobInventory(note: UUID) throws -> BlobInventory      // files in att/, references per revision, unreadable revisions
    public func collectBlobs(note: UUID, state: inout BlobCollectorState, now: Date, dryRun: Bool) throws -> BlobCollectionReport
    // changeRecipients(…, policy: RewrapPolicy) extends the existing recipient-change API
}
public protocol BlobSource: Sendable {                                           // Sempere (B2); a per-note view of Vault conforms
    func data(for ref: BlobRef, maxBytes: Int) throws -> Data
    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T
}

// SempereRender (C1–C3)
public protocol PDFPageRasterizer: Sendable { func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int) throws -> RGBAImage }
public protocol TextShaper: Sendable { func shape(_ text: TextContent, frame: Rect) throws -> ShapedText }   // glyph runs + font programs to subset; CLI default, app via CoreText
// RenderOptions gains: blobs: (any BlobSource)?, pdfRasterizer: (any PDFPageRasterizer)?, shaper: (any TextShaper)?, recordings: RecordingExport, keepImageMetadata: Bool
// Writers gain a `report` (placeholders, warnings) output.
```

### A. Core model, ops, merge (`Sources/Sempere`; Opus)

**A0 — model types.** Types above with Codable exactly per `format.md` §8
(lowercase UUIDs, 3-decimal rounding, omitted defaults, integer `layer`),
`extra` preserved byte-equivalently (decode → encode round trip of every
`format.md` §8 example and of an item with unknown kind, unknown layer
number and unknown fields), `Op` encoding and decoding of the six new ops,
`setItem` field validation (immutable field → error; `null` rules),
`Transcript` Codable, `BlobRef.kind`. No merge changes beyond compiling
(`NoteReducer` may ignore the new ops with a `// A1` marker; the PR must not
be released alone).
*Done when:* JSON tests for every example; unknown kind/field/layer round
trip; invalid `setItem` rejected; `swift test` green.
*Status:* in review (#47). Code: `Sources/Sempere/Attachments.swift`,
`JSONValue.swift`, the ops in `Model.swift`; tests `AttachmentModelTests`
and the `attachment-json` / `transcript` fuzz targets. For A1: the reducer
and `RestoreSummary` skip the six ops at the `// A1` markers, and
`SnapshotBuilder.makeSnapshot` throws `NoteLogError.attachmentsNotMerged`
for any input that `Revision.holdsAttachments`, so no snapshot can drop
them in the meantime; A1 removes that guard and the error case.

**A1 — merge, snapshots, history.** `NoteReducer`: items and recordings as
sets with permanent tombstones and covered-add removal; registers per (item,
field) and (recording, field) with snapshot `clocks` and the `.base` rule;
orphans for `addItem`/`setItem` (unknown page or item) and `setRecording`
(unknown recording); a removed page removes its items; snapshot output sorted
(`(layer, z, id)`, `(started, id)`), `origin` on every item and recording.
`History`: restore diff for items and recordings (present by id or `parent`
with equal immutable fields; registers via `setItem`/`setRecording`),
`RestoreSummary` counts. `NoteSummary`: item and recording counts, typed text
for search, blob references of the note (for the index and collection).
*Done when:* the shuffled-order property test covers items and recordings;
scenario tests: concurrent `setItem(frame)` (higher stamp wins, both orders),
move vs crop on different fields (both apply), `removeItem` vs concurrent
`setItem` (stays removed), `setItem` arriving before its `addItem` (orphan,
excluded from `included`, applied once the add arrives), late `setItem` on a
compacted-away removed item (no-op, covered), snapshot of an unknown kind
re-emitted unchanged, restore of a deleted image twice writes nothing the
second time; fixture vault gains a note with one item of each kind (B2 adds
the blobs).

### B. Blob store, rewrap, collection, sync

**B1 — Age streaming and header rewrap** (`Sources/Age`; Opus). Streaming
encrypt (input file or chunk sequence → output file), streaming decrypt
(chunk iterator that releases only authenticated chunks),
`rewrapHeader(of:identities:to:)` that keeps the file key, and a streaming
re-encrypt (decrypt → encrypt under a new file key) for the full
re-encryption path.
*Done when:* CCTV vectors pass through the streaming paths; a 300 MB round
trip runs with bounded memory (chunk-level API, no whole-file `Data`);
interop with the `age` CLI both ways for streamed files and for a rewrapped
header; a truncated or reordered chunk is rejected at the right chunk.

**B2 — blob store, verify, rewrap, collection, CLI** (`Sources/Sempere`,
`Sources/SempereCLI`; Opus). Per-note `att/` paths with kinds, names,
framing, Padmé, write/read/verify/copy (streaming, via B1; start on the
one-shot API if B1 is not merged), revision listings skip `att/`,
`Vault.verify` reports blobs per note (`missing`, `invalid`, `unreferenced`,
`staleRecipients`, `unknownFile`), recipient change covers blobs with
`RewrapPolicy` (header-only on add, full re-encryption on removal or
recipient-type change by default; `rekeyBlobs` in the journal; rename on
removal; journal fallback lookup; resumable), `features` in `vault.json`,
per-note inventory and collection per `format.md` §8.1.6 with device-local
state (`$XDG_STATE_HOME/sempere/blobs/<vaultId>.json`; the app keeps its
own in Application Support). CLI: `sempere blobs list [NOTE] | verify |
extract NOTE SHA256 [--out] | unused [NOTE] | gc [--dry-run] [NOTE…] |
repair`, `vault recipients add|remove … [--rewrap header|reencrypt]`,
`recover` extracting a note's attachments with the stock framing.
*Done when:* tests for name binding (renamed file, swapped content,
non-zero padding, wrong length, wrong kind suffix all rejected or
unresolved), Padmé sizes, the stock recovery commands of `format.md` §8.1.7
against the real `age` CLI, rewrap add/remove interrupted and resumed in
both methods (names, stanza counts, and for re-encryption a changed file
key), collection blocked by each of rules 1–4 separately, collection of one
note unaffected by an unreadable revision in another, collection never
removing a blob that a surviving restore point needs, fixture vault with
blobs.

**B3 — WebDAV sync of blobs** (`Sources/SempereWebDAV`; Sonnet, Opus review).
Each note's `att/` collection per §4 above; streaming GET to a temp file and
PUT from a file; `maxBlobBytes` (default 1 GiB + 64 MiB) separate from
`maxFileBytes`; deletion only under rules 1–3 for the note on the deleting
side; remote names validated (`<64 hex>.<kind>.age`).
*Done when:* mock-server tests for each row of the write-once table with
blobs, a dropped-but-referenced blob is copied back, a hostile name is
ignored, a 300 MB blob syncs with bounded memory; wsgidav integration test.

### C. SempereRender export

**C1 — images** (`Sources/SempereRender`; Sonnet, Opus for the JPEG decoder).
Placement math (`format.md` §8.5.1 tables), PDF Image XObjects (JPEG
DCTDecode passthrough with SOF parsing and metadata stripping on export;
PNG decode → Flate + SMask), SVG data URIs and `--assets`, PNG raster with a
PNG decoder and a baseline + progressive JPEG decoder (with DCT scaling),
HEIC as a placeholder plus warning (app: decoded via its hook), placeholders,
`BlobSource` plumbing, export report.
*Done when:* golden tests for every orientation, crop and rotation in all
three formats; JPEG decoder matches reference decodes (libjpeg-turbo output
committed as fixtures) within ±2 per channel; an exported JPEG carries no
APP1 even when the blob does; malformed and truncated inputs fail cleanly
(fuzz test); the 100 MP cap is enforced.

**C2 — text** (`Sources/SempereRender` + font resources; Opus). Bundled Noto
Sans/Serif/Mono (package resources; the static CLI artifact ships the
resource bundle next to the binary, CI updated), font-pack discovery and
selection by `cmap` coverage and `lang`, OpenType reader (`head`, `hhea`,
`maxp`, `cmap` 4/12/14, `hmtx`, `loca`, `glyf` including composite glyphs,
`CFF ` for CJK packs, GSUB/GPOS subset of §6), UAX #9, #14 and #29, layout
per `format.md` §8.5.3 honouring `breaks`, the `TextShaper` protocol with
the CLI's default implementation, **font subsetting** (TrueType and CFF) for
PDF (Type0 + `ToUnicode`) and SVG (`@font-face`), raster glyphs, the
missing-script report.
*Done when:* layout unit tests (stored breaks honoured, invalid breaks
ignored, UAX #14 fallback, long word, alignment with `start`/`end` in LTR
and RTL, mixed sizes, empty lines, tabs); an Arabic and a Hebrew line
reorder and join correctly against reference renderings; with a CJK font
pack, `pdftotext` (poppler) extracts the CJK text and `pdffonts` shows only
subset fonts; without it, the warning names the script; goldens.

**C3 — PDF backgrounds** (new target `Sources/SemperePDF`, `Sources/SempereRender`,
`Sources/SempereCLI`; Opus). The reader subset of §10, page boxes and count,
Form XObject import, `PDFWriter` 1.7 when embedding, SVG/PNG via a
`PDFPageRasterizer`: the CLI's Poppler rasterizer (§10) when `pdftoppm` or
`pdftocairo` is installed, else a placeholder with a warning.
*Done when:* fixtures covering classic xref, xref stream + object streams,
incremental update, broken xref (repair), inherited boxes and `/Rotate` 90,
encrypted (refused); exported PDFs open in poppler (`pdftoppm`) with the
background in the right place (pixel comparison against `pdftoppm` of the
source page, small tolerance); SVG/PNG exports with Poppler on PATH show the
page, without it a placeholder and the warning; a hostile PDF that makes the
Poppler process hang or crash yields a placeholder, not a hung export; the
fuzz test never crashes; portability check passes (no `Process` outside the
CLI target).

**C4 — recordings in exports** (`Sources/SempereRender`, `Sources/SempereCLI`;
Sonnet). `--recordings none|list|attach` (combinable: `list,attach`), the
list page (uses C2's text), PDF embedded files (audio and transcript text),
`export --format media`.
*Done when:* `pdfdetach -list` shows the attached audio; the list page shows
title, start time, duration and transcript.

### D. Notability import (`Sources/SempereImport`; Opus for reverse engineering, Sonnet after)

Each starts by answering its unknowns in §11 on the user's backup (findings go
into `docs/import-notability.md`, never the data itself) and by extending the
synthetic `.note` fixture so CI covers the mapping.

- **D1 — PDF backgrounds** (needs C3's `SemperePDF` for page boxes; can start
  with `pageSize` from thumbnails). *Done when:* the 26 PDF notes import with
  their pages at the right bands (`RealNotabilityTests` checks recognition
  origins still align; the eval oracle compares with PDF-composited
  thumbnails), `dropped.pdfPages` is 0, template PDFs handled or reported.
- **D2 — images.** *Done when:* the 4 image notes import their images where
  the thumbnails show them; non-JPEG/PNG reported.
- **D3 — typed text.** *Done when:* synthetic fixture with styled text maps
  to runs (including a non-Latin run with its `lang`); real notes with text
  import it (if the backup has any).
- **D4 — recordings and ink sync.** *Done when:* recordings import with
  duration and title; strokes carry `rec` where `eventTokens` (or the newer
  equivalent) say so, verified by listening to a sample.

### E. App (`Apps/`; Opus for E0/E3, Sonnet for the rest)

- **E0 — attachment plumbing:** `NoteWriter.addBlob`/`copyBlob`,
  `BlobCache` (verified temp plaintext files, LRU, cleared on lock), lazy
  per-kind iCloud download of a note's `att/`, `ItemLayerView` between
  `PaperView` and the canvas with placeholders, item
  selection/move/resize/rotate/delete/copy overlay, items in undo. *Done
  when:* app tests with an in-memory vault cover add/move/delete/copy-to-note
  through `NoteWriter`; one delta per gesture; iCloud logic tests in
  `CloudScan` style (an unlisted `att/` never makes a note pending).
- **E1 — images:** Photos picker, camera, paste/drop, the privacy setting
  (HEIC → JPEG and metadata stripping, on by default), orientation, crop UI.
  *Done when:* with the setting on, a HEIC with GPS becomes a JPEG blob
  without APP1; with it off, the HEIC is stored as picked and still exports
  without location; orientation 6 photo displays upright.
- **E2 — text boxes:** text tool, editor overlay with system fonts, styles
  (bold, italic, underline, colour, size, alignment, family), `lang` and
  `dir`, `breaks` from TextKit, committed text drawn by CoreText per
  `format.md` §8.5.3, the app's `TextShaper` (CoreText glyphs and font
  tables for subsetting), search hits highlighted. *Done when:* text in
  Latin, CJK and Arabic typed on iPad exports (app) with identical lines and
  correct glyphs, and the CLI export of the same note has the same line
  breaks (snapshot test of line ranges).
- **E3 — PDF import and backgrounds:** import as a new note or insert pages,
  unlock/decrypt, tiled display, PDFKit `PDFPageRasterizer`. *Done when:* a
  200-page PDF imports, scrolls and zooms without memory warnings on the
  simulator; encrypted PDF flow tested.
- **E4 — recording and playback:** record with the configured format
  (segmented), background audio, interruptions, list per note, playback with
  ink highlighting, tap stroke to seek, `rec` on strokes and items. *Done
  when:* recording survives a simulated interruption; `rec.at` within 0.1 s
  in a scripted test; each codec choice produces a playable `audio/mp4`;
  tested on the user's iPad (A12Z, 26.7.1).
- **E5 — transcription:** SpeechTranscriber → DictationTranscriber →
  SFSpeechRecognizer on-device fallback, locale and asset checks, transcript
  view with read-back word highlighting and low-confidence marking, tap word
  to seek, search. *Done when:* availability matrix verified on the user's
  iPad and recorded in `docs/`; transcript JSON validates against
  `format.md` §8.3.2 (segments and, where the engine gives them, words).
- **E6 — Settings panel:** one Settings screen (sheet from the library) with
  the sections of §15: recording (codec, quality, sample rate, channels,
  size per hour), photos (privacy and HEIC), transcription (opt-in, locale),
  device keys (rewrap method when adding; when removing or upgrading, with
  the warning), storage (unused attachments, from E7). Stored in
  `UserDefaults` (`@AppStorage`) per device; nothing in the vault. *Done
  when:* every setting has a unit-tested model and is read by the feature
  it controls; defaults match §15; the PQ/removal "headers only" choice
  needs a confirmation.
- **E7 — attachment index and unused-attachments UI:** the device-local
  index of §4 (Application Support, per vault and note, updated by every
  `NoteWriter` write and every sync arrival, using A1's per-note
  references), "Unused attachments: N items, X MB" in Settings, the
  browsable list (preview, the note and its history, became-unused date,
  Delete honouring the 30-day window, "Delete all eligible"), the
  "held by history" total. *Done when:* index updates touch only the changed
  note (test with a counting vault fake); a blob becomes deletable exactly
  30 days after it was first seen unreferenced; a late delta that references
  it again resets it; delete goes through B2's per-note collection.

### F. CLI and search (`Sources/SempereCLI`; Sonnet)

`notes show` lists items and recordings; `search` covers typed text and
(`--transcripts`) transcripts; `export` wires the note's blobs as
`BlobSource`, the Poppler rasterizer and the font packs; `import pdf FILE`
(needs C3) and `attach image|audio NOTE FILE` for scripted use and tests.
*Done when:* end-to-end CLI tests: import a PDF, attach an image and audio,
export PDF with backgrounds and attachments, search finds typed text.

### G. Future item kinds (not scheduled)

- **G1 — `math` items.** Define `format.md` §8.2.7 `math` fully; typeset
  with SwiftMath (MIT; MathJax as fallback, §6) on device; edit as LaTeX
  source in the text editor with a live preview; store the rendered PDF
  blob for other renderers; exports embed that PDF as a Form XObject (C3's
  machinery). Later and separate: handwriting → LaTeX on device.
- **G2 — `video` items.** Define `format.md` §8.2.7 `video` fully; record
  or pick a clip, poster frame, `AVPlayer` playback, 1 GiB cap, "PDF +
  attachments" embeds the clip, SVG/PNG draw the poster.

### L. Localization (future; contributions welcome)

Localize the app's interface with String Catalogs (`.xcstrings`): move every
user-visible string into a catalog, add plural and device variants, check
layouts with the pseudo-languages (double length, right to left). **Spanish
first**; other languages from contributors, with a short guide in
`CONTRIBUTING` on adding one. The CLI's messages stay English. This is
interface text only; note content was already full Unicode (§6).

### Dependencies

```
A0 ──► A1
A0 ──► B2 ──► B3          B1 ──► B2 (B2 may start on one-shot Age)
A0 ──► C1, C2, C3, C4     (C* need BlobSource from B2: stub it in tests)
C3 ──► D1 (SemperePDF); A0 ──► D2, D3, D4 (write through B2)
A1 + B2 ──► E0 ──► E1, E2, E3, E4 ──► E5
E0 ──► E7 ──► E6 (storage section); E6's other sections only need the feature they configure
C2 ──► E2 (TextShaper), C4
A1 + B2 + C* ──► F
C3 + E2 ──► G1;  E4 ──► G2;  L independent
```

## 15. Settings

All settings are per device (`UserDefaults`), never stored in the vault, and
live in one Settings panel (task E6). Defaults are the decided policy.

| Section | Setting | Default | Notes |
| --- | --- | --- | --- |
| Recording | Codec | AAC-LC | AAC-LC, HE-AAC, Apple Lossless (§9) |
| | Quality | 64 kbit/s | shows size per hour |
| | Sample rate | 48 kHz | |
| | Channels | mono | stereo only with a stereo input |
| Transcription | Transcribe recordings on this device | off (opt-in) | locale, model download status |
| Photos | Remove location and camera data, convert HEIC to JPEG | on | §7; exports strip location regardless |
| Device keys | When adding a device | rewrite headers only | alternative: re-encrypt everything (§3) |
| | When removing a device or upgrading to post-quantum keys | re-encrypt everything | alternative: rewrite headers only, with a warning and a confirmation |
| Storage | Unused attachments: N items, X MB | — | browsable list, delete after 30 days unreferenced (§4) |

The device-key settings explain in the panel that *devices* here are the
vault's keys (this iPad, that Mac, the paper backup), not people: sharing a
note means exporting it.

## 16. Decisions

All decisions are final (maintainer review, 2026-10-05).

1. **Changed:** per-note storage, `notes/<id>/att/<keyed-hash>.<kind>.age`;
   dedupe only within a note; copying an item to another note copies the
   blob; collection is per note.
2. Keyed blob names, HMAC(vaultSecret, sha256(content)), double as the
   integrity tag; no tag inside blobs.
3. **Final:** rewrap policy chosen automatically: adding a device →
   header-only rewrite; removing a device or migrating to post-quantum
   recipients → full re-encryption with new file keys. Two settings expose
   the two cases. Recipients are device keys, not sharing.
4. Padmé padding of blobs.
5. Mutable items with LWW registers.
6. Ink above all items; **changed:** integer z-layers (background 0,
   content 100), open for more layers later.
7. **Changed:** full Unicode; system fonts in the app; font subsets embedded
   in exports; Noto in the CLI plus optional font packs with a clear
   missing-script report; consistent layout from fixed vertical metrics and
   stored line breaks. Future: UI localization (Spanish first), reserved
   `math` item.
8. AAC-LC, mono, 48 kHz, 64 kbit/s by default; **changed:** configurable in
   Settings; reserved `video` item.
9. Transcripts as separate encrypted JSON: time-stamped segments plus
   optional per-word timings and confidence, language, engine and version;
   on device only, opt-in.
10. **Final:** immutable `rec: {id, at}` on strokes and items for
    tap-to-seek and playback highlighting.
11. Open item kinds and fields (degrade to placeholders); ops stay
    fail-closed.
12. PDF import: one finite page per PDF page; Notability: bands.
13. **Final:** Linux CLI renders PDF backgrounds for SVG/PNG with Poppler
    (`pdftoppm`/`pdftocairo`, a separate process) when installed, else a
    placeholder and a warning; PDF export always embeds the original page;
    Apple platforms use PDFKit.
14. **Final:** recordings omitted from PDF by default; the app offers "PDF"
    and "PDF + attachments"; CLI `--recordings attach|list`.
15. **Changed:** the app keeps a continuous per-note index of unused
    attachments, shown in Settings with a browsable list; deletion keeps the
    30-day window.
16. Limits: 1 GiB per blob, 64 KiB per text item, 100 MP images.
17. **Changed:** metadata stripping and HEIC → JPEG are a setting, on by
    default.
18. `features` in `vault.json`.
19. `DESIGN.md`: typed text boxes and audio leave the non-goals; no AI
    services, and future smart features are on-device only.
