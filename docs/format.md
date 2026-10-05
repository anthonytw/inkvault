# InkVault on-disk format, version 1

Normative. Changes to this file are format changes and need a version bump
or a documented compatible extension.

## 1. Vault layout

A vault is a directory whose name ends in `.inkvault`.

```
Notes.inkvault/
  vault.json                              plaintext manifest (§2)
  keys/
    <recipient>.key.age                   optional passphrase-wrapped identity (§3)
  notes/
    <noteId>/
      <hlc>-<device>-<seq>.delta.age      append-only revision (§5)
      <hlc>-<device>-<seq>.snapshot.age   append-only snapshot  (§5)
```

Everything under `notes/` is written once and never modified. The only
exception is a recipient change (§3.3), which rewrites files in place.

Unknown files and directories must be ignored, never deleted.

## 2. vault.json

```json
{
  "format": "inkvault/1",
  "vaultId": "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c",
  "created": "2026-10-04T16:20:00Z",
  "recipients": [
    { "key": "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p",
      "label": "Anthony's iPad", "added": "2026-10-04T16:20:00Z" }
  ],
  "vaultSecret": "-----BEGIN AGE ENCRYPTED FILE-----\n...\n-----END AGE ENCRYPTED FILE-----\n"
}
```

- `recipients[].key`: age X25519 recipient (Bech32, HRP `age`). At least one.
- `vaultSecret`: 32 random bytes, age-encrypted and armored, to exactly the
  listed recipients. It keys the inner authentication tag (§4) and nothing
  else. It is rotated whenever a recipient is removed.

## 3. Keys

### 3.1 Identity

An age X25519 identity, Bech32 with HRP `AGE-SECRET-KEY-`, exactly as
`age-keygen` produces. The corresponding recipient is derived from it.

### 3.2 Passphrase-wrapped identity file

`keys/<recipient>.key.age` is an age file encrypted with a single scrypt
(passphrase) recipient. Its plaintext is an `age-keygen` style file:

```
# created: 2026-10-04T16:20:00Z
# public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
AGE-SECRET-KEY-1QGFZ...
```

`age -d keys/<recipient>.key.age` with the passphrase must work. Writers
use an scrypt work factor between 15 and 18; readers must accept any work
factor up to 20, may accept up to 22, and may refuse larger with an error.
The reader cap exists because scrypt at work factor w needs 2^w × 1 KiB of
memory (20 → 1 GiB, 22 → 4 GiB), beyond what the iPad target can allocate.

The file is optional. A vault may be used with an identity that is only
in a device Keychain or supplied externally.

### 3.3 Changing recipients

Adding a recipient: append it to `recipients`, re-encrypt `vaultSecret`
to the new set, then re-encrypt every file under `notes/` to the new set
(new file key and header). Removing a recipient: the same, with a freshly
generated `vaultSecret`. These are the only in-place rewrites in the format;
do them from one device while others are idle.

In both cases the `gzip(JSON)` bytes of every body (§4) are unchanged. On
removal each body is also re-tagged under the new `vaultSecret`, after its
existing tag has been verified under the outgoing secret. A file whose tag
does not verify is left as it is and reported; it is never re-tagged.

#### 3.3.1 Resumable procedure

Implementations SHOULD change recipients as follows, so that an interrupted
change can be finished by any device holding an identity of the new set:

1. Write `rewrap-journal.json` at the vault root (atomically, and durably
   before step 2):

   ```json
   { "format": "inkvault/1",
     "previousVaultSecret": "-----BEGIN AGE ENCRYPTED FILE-----\n...\n" }
   ```

   - `format`: `inkvault/1`.
   - `previousVaultSecret`: present only when the secret is rotated
     (removal): the outgoing 32-byte vault secret, age-encrypted and
     armored to the **new** recipient set. Absent when adding.
2. Write `vault.json` with the new `recipients` and `vaultSecret`.
3. For every file under `notes/`, skip it if it is already complete (below);
   otherwise rewrite it as described above, verifying its tag under the
   current secret or, failing that, under `previousVaultSecret`, and replace
   it atomically (temporary file in the same directory, then rename).
4. Delete `rewrap-journal.json` once every file is complete. If any file
   could not be read or verified, keep the journal (it is the only copy of
   the outgoing secret), report those files, and retry step 3 later.

A file is complete when its age header has exactly one `X25519` stanza per
current recipient (and no other stanzas) and its tag verifies under the
current `vaultSecret`. X25519 stanzas do not name their recipient, so this
count is the only header-level check; while a journal exists no other
recipient change is started, so counts from two changes never mix.

If `rewrap-journal.json` exists when a vault is opened, the change is
unfinished: a writer finishes steps 3 and 4 before any other recipient
change, and may verify tags under `previousVaultSecret` meanwhile. Readers
that do not implement this procedure treat the journal as an unknown file
(§1).

## 4. Encrypted file bodies

Every `.age` file under `notes/` is an age v1 file whose plaintext is:

| Offset | Size | Content |
| --- | --- | --- |
| 0 | 4 | ASCII `INKV` |
| 4 | 1 | body version, `0x01` |
| 5 | 32 | HMAC-SHA256 tag (below) |
| 37 | rest | `gzip(JSON)` (§5), gzip framing so `gunzip` reads it |

Tag = HMAC-SHA256(key = vaultSecret,
message = `"inkvault/1" ‖ 0x00 ‖ noteId ‖ 0x00 ‖ filename ‖ 0x00 ‖ gzipBytes`),
where `filename` is the file's base name (e.g. `00017596...-a1b2c3d4-12.delta.age`)
and `noteId` is the note directory name. Binding the file name stops a
revision being replayed under another note or name.

Readers must verify the tag when the vault secret is available and must
report, not silently drop, files that fail. Recovery without the app:

```
age -d -i key.txt FILE.age | tail -c +38 | gunzip | jq .
```

## 5. Revisions

Each file under `notes/<noteId>/` is one revision. Name:

```
<hlc>-<device>-<seq>.<delta|snapshot>.age
```

- `hlc`: hybrid logical clock, 17 ASCII digits: 13-digit Unix milliseconds
  followed by a 4-digit counter, both zero-padded. Lexicographic order of
  `hlc` is causal-ish time order. The clock follows the usual HLC rules:
  on every local event or received revision, `millis = max(wall, seen)`,
  counter increments on ties and resets otherwise. A device does not adopt
  a received `hlc` more than 24 hours ahead of its own wall clock; such a
  revision still merges using its `hlc` exactly as written.
- `device`: 8 lowercase hex chars, random per app installation. Never a
  hardware identifier.
- `seq`: per (note, device) counter, decimal, starting at 1, gap-free,
  at most 2^53 − 1 (9007199254740991, the largest integer every JSON
  implementation holds exactly). A writer chooses `seq` greater than every
  `seq` for its device that appears in a file name of the note or is covered
  by any snapshot's `included` (§5.3), so a seq whose file was compacted away
  is never reused. Readers reject a larger `seq` in a file name, a revision
  or `included` (§8).

Ordering key for anything that needs a total order: `(hlc, device, seq)`.

A reader must reject a revision whose JSON `noteId`, `device`, `seq` or
`hlc` (§5.1) disagree with its directory name or file name, and report it
like any other unreadable file.

### 5.1 Common fields

```json
{
  "type": "delta",
  "noteId": "…",
  "device": "a1b2c3d4",
  "seq": 12,
  "hlc": "17596320000000003",
  "wall": "2026-10-04T16:20:00.123Z",
  "app": "inkvault-ios/0.1"
}
```

`wall` is informational (history UI). `app` is informational.

### 5.2 Delta

Adds `"ops": [Op, ...]`, applied in order. Ops:

| op | fields | effect |
| --- | --- | --- |
| `addStroke` | `page`, `stroke` | add stroke to page (no-op if page removed) |
| `removeStroke` | `page`, `strokeId` | remove stroke; wins over any add |
| `addPage` | `page: {id, order, parent?}` | add an empty page |
| `removePage` | `pageId` | remove page and its strokes; wins over adds |
| `setPageOrder` | `pageId`, `order` | LWW on the page's order key |
| `setPageRecognition` | `pageId`, `recognition` | LWW on the page's recognised text (§5.5); `null` clears it |
| `setMeta` | `field`, `value` | LWW per field (§5.4) |
| `deleteNote` | | LWW with `restoreNote` on `deleted` |
| `restoreNote` | | |

The LWW timestamp of an op is the revision's `(hlc, device)`. `addPage`
adds the page empty; strokes go in `addStroke` ops. A stroke id is never
added again after it has been removed; a writer that undoes an erase, or
restores from history, must mint a new id and may set `parent` to the old
one. The same holds for page ids.

### 5.3 Snapshot

Adds:

```json
"included": { "a1b2c3d4": { "upTo": 12, "extra": [15, 16] },
              "99ee00ff": { "upTo": 3,  "extra": [] } },
"state": State
```

`included` names every revision the snapshot already reflects: for each
device, all `seq ≤ upTo` plus the listed `extra` (seen out of order).
`included` must list only deltas the snapshot applied in full: a delta with
an `addStroke`, `setPageOrder` or `setPageRecognition` naming a page the
writer has not seen is left out, so it is applied again once the page arrives. (Removals of unseen
ids are recorded as tombstones instead, §5.4.)

Readers reconstruct a note as the merge of every snapshot present plus every
delta not covered by any snapshot's `included`. Pages and strokes merge as
sets: an item is present if some snapshot holds it or an uncovered delta adds
it, unless a tombstone or an uncovered remove names it, its page is gone, or
some snapshot covers the revision in its `origin` (§5.5, §5.6) but does not
hold it. Metadata, page order and `deleted` merge by LWW, using each
snapshot's recorded clocks and each delta op's own timestamp.
Reconstruction is order-independent: the same set of revisions gives the
same state whatever order they are read in, and implementations must have a
test that reconstructs from shuffled revision orders and compares.

A device may write a snapshot at any time. A delta may be deleted when at
least one snapshot covers it and it is older than the retention window
(default 30 days by `wall`). A snapshot may be deleted when another
snapshot's `included` is a superset of its `included` and it is older than
the window; of two snapshots with equal `included`, keep at least one.

### 5.4 State and metadata

Tags are matched case-insensitively ("Math" and "math" are one tag) with
inner whitespace runs collapsed (multi-word tags are fine). Writers must not
put two tags that differ only in case on one note (the first spelling wins),
and apps list a tag with its first-seen spelling; readers must accept any
stored `tags` array unchanged. Matching never changes merging: `tags` is one
LWW register holding the whole array (below), so concurrent "Math" and
"math" resolve like any other concurrent write, a removal (a later write
without any spelling of the tag) is never undone by an older write in
another spelling, and vaults written before this rule (two spellings on one
note) stay valid. Titles are labels, never keys: any number of
notes may share a title, in one notebook or several.

```json
{
  "deleted": false,
  "meta": {
    "title": "Lecture 3",
    "tags": ["math", "fall"],
    "notebook": "School",
    "favorite": false,
    "created": "2026-10-04T16:20:00Z",
    "paper": { "kind": "ruled", "spacing": 24,
               "background": "#FFFFFFFF", "lineColor": "#D0D8E8FF" },
    "pageSize": { "width": 612, "height": 792, "infinite": false }
  },
  "pages": [ Page, ... ]
}
```

- `created` is set once by the first revision and never changes. Readers take
  the earliest of any snapshot's recorded `created` and the `wall` of the
  earliest known revision by `(hlc, device, seq)`.
- `notebook` is a free string (or `null`: in no notebook). `/` separates
  the levels of a display hierarchy: `Research/Daily log` is the notebook
  `Daily log` inside `Research`. For display, grouping and filtering, each
  segment is trimmed of whitespace and empty segments (leading, trailing or
  doubled `/`) are dropped, so `" Research//Daily log/ "` names the same
  notebook; a name with no segment left is no notebook. Writers should store
  this canonical form but readers must not rely on it. Parent levels exist
  implicitly (no note needs to be in `Research` itself), and selecting a
  notebook shows the notes in it and in every notebook below it. Renaming or
  moving a notebook is one `setMeta` of `notebook` per affected note,
  replacing the old path prefix; there is no separate notebook object.
- `paper.kind` ∈ `blank`, `ruled`, `grid`, `dot`. Lengths are points (1/72 in).
- `pageSize.infinite: true` means the page grows downward; `height` is then
  the current extent.
- `pageSize.breakHeight` (optional, points): for an infinite page, the height
  of each page a paginating exporter (PDF) splits it into. Absent, it
  is `width × 11 / 8.5` (letter aspect). Ignored for finite pages.
- In a snapshot, `pages` are sorted by `(order, id)`.

`State` may carry `"clocks"`, mapping each LWW register (`title`, `tags`,
`notebook`, `favorite`, `paper`, `pageSize`, `deleted`) to the stamp of the
op that last set it, encoded `"<hlc>-<device>"`, e.g.
`{"title": "17596320000000003-a1b2c3d4"}`. A delta the snapshot does not
cover wins a register only if its own `(hlc, device)` is greater than that
stamp; between snapshots, the greater recorded stamp wins. A register with
no clock is treated as stamped by the snapshot's own `(hlc, device)`.

`State` may carry `"tombstones": {"strokes": [uuid, ...], "pages": [uuid, ...]}`.
A delta adding a tombstoned id stays removed. `strokes` lists ids whose
`removeStroke` was seen while the revision that added the stroke was not yet
covered by `included`; once it is covered, the tombstone may be dropped.
`pages` lists every removed page id and is never pruned, so a late op on a
removed page is a no-op rather than an orphan (§5.3). Both fields are
omitted when empty.

### 5.5 Page

```json
{ "id": "…", "order": "a0", "strokes": [ Stroke, ... ], "recognition": Recognition, "parent": "…" }
```

`recognition` is optional (below). `parent` is optional: the id of a removed
page this one re-creates (a restore from history, §5.7). It is
informational, set by the `addPage` that adds the page and carried into
snapshots; readers that do not know it may ignore it.

`order` is any string; pages sort lexicographically by `(order, id)`. The
library provides a helper to generate a key between two neighbours.

In a snapshot, a page may carry `"orderClock"`, the `"<hlc>-<device>"` stamp
of the `addPage` or `setPageOrder` that set its `order`, with the same LWW
rule and default as `clocks` (§5.4).

#### Recognised text

A page may carry `"recognition"`, the text recognised in its handwriting:

```json
"recognition": {
  "engine": "pencilkit-27.0",
  "text": "Lecture 3\nlinear maps",
  "words": [ { "t": "Lecture", "box": [52.5, 40.0, 96.25, 30.5] }, ... ]
}
```

- `engine`: free-form name and version of whatever produced the text, e.g.
  `pencilkit-<iPadOS version>` or `notability-<version>` for an import.
- `text`: the page's recognised text in reading order, lines separated by `\n`.
- `words[].t`: one word of `text`; `words[].box`: its bounding box
  `[x, y, w, h]` in page coordinates (points, origin top-left, y down).
  Writers round to at most 3 decimals. `words` may be empty.

Recognition is derived data: it is set as a whole, never merged, and a writer
may replace it at any time (for example after strokes change). It is an LWW
register per page, set by `setPageRecognition`. In a snapshot, a page with
`recognition` or a page whose recognition was cleared carries
`"recognitionClock"`, the `"<hlc>-<device>"` stamp of the op that last set it,
with the same LWW rule as `orderClock` (a `recognition` without a clock is
stamped by the snapshot's own `(hlc, device)`). A page with neither `recognition` nor
`recognitionClock` has never had recognition set and does not compete with
a `setPageRecognition` the snapshot does not cover. `addPage` ignores any
`recognition` in its page object (the page is added empty, §5.2).

Readers that index text for search use `text`; `words` lets a viewer
highlight hits on the page.

In a snapshot, every page and stroke carries `"origin"`,
`"<hlc>-<device>-<seq>-<op>"`: the revision that added it and the op's
index in that revision. A snapshot whose `included` covers that revision but
which does not hold the item has seen it removed. Strokes on a page are
ordered by `origin`. An item without `origin` is treated as added by the
snapshot holding it, at op index equal to its position.

### 5.6 Stroke

```json
{
  "id": "…",
  "ink": { "tool": "pen", "color": "#1A1A1AFF", "width": 2.5 },
  "points": [ [x, y, t, w, h, o, f, az, al], ... ],
  "transform": [1, 0, 0, 1, 0, 0],
  "parent": "…"
}
```

- `tool` ∈ `pen`, `pencil`, `marker`, `monoline`, `fountainPen`,
  `watercolor`, `crayon`. Unknown tools render as `pen`.
- `color` is `#RRGGBBAA`.
- `points` are the control points of a uniform cubic B-spline, as
  PencilKit's `PKStrokePath` exposes them: location `x,y` in points with
  origin top-left and y down; `t` time offset in seconds; `w,h` the width
  the ink is drawn at, in points (the nib's extent across the stroke, as
  InkRender draws it); `o` opacity 0...1; `f` force; `az` azimuth and `al`
  altitude in radians. Writers round to at most 3 decimals.
- `w,h` are not `PKStrokePoint.size`: PencilKit draws a pen of size `s`
  `2s − 4` wide (nothing below 2), so a PencilKit reader or writer converts
  per ink (the app's `NibSize`, measured on iPadOS 26 and 27).
- `transform` is an optional affine matrix `[a b c d tx ty]`; identity when
  absent.
- `parent` optionally names the stroke this one was sliced from.
- A stroke id is never added again after it has been removed; a writer that
  undoes an erase, or restores from history, must mint a new id and may set
  `parent` to the old one.
- `origin` appears only in snapshots (§5.5).

### 5.7 History and restore

Every revision is a restore point, ordered by `(hlc, device, seq)`, and
shows its `wall`, `device`, `app` and kind. The note **as of** revision R is
the reconstruction (§5.3) of every revision ordered at or before R. For a
delta this is not necessarily what R's writer saw (a concurrent revision with
a smaller `hlc` is included, one with a larger is not); it is the only
definition every reader can compute the same way.

Compaction (§5.3) deletes revisions; they are no longer restore points. A
surviving revision R can still be shown only if each deleted revision is
covered by the `included` of a snapshot ordered at or before R, or is
provably ordered after R (R itself, or a surviving revision ordered after
R, of the same device with a smaller `seq`, precedes it). Otherwise readers
report R as incomplete and do not show or restore it. Likewise for an
unreadable revision ordered at or before R, and for every R while any
snapshot is unreadable (it may be the only record of compacted revisions).

Restoring a note to R never rewrites or deletes history. A writer appends
one delta whose ops turn the current state into the state as of R:

- pages and strokes present now but not as of R: `removePage` /
  `removeStroke`;
- pages and strokes present as of R but removed since: re-added under new
  ids (`addPage`, `addStroke`; a re-added page gets its strokes and its
  recognition from R), with `parent` set to the old id (§5.2);
- `setPageOrder`, `setPageRecognition`, `setMeta` for every page order,
  recognition and metadata register that differs, and `deleteNote` or
  `restoreNote` if `deleted` differs.

A page or stroke counts as present when its id is, or when an item with
`parent` naming it is (for a stroke, also with the same `ink`, `points` and
`transform`), so restoring the same point twice writes nothing the second
time. The delta's `hlc` is issued after observing every revision of the
note, so its LWW ops win over what they set back. Re-added strokes are
drawn above the strokes that stayed (they sort by their new `origin`).
Concurrent revisions the restoring device has not seen merge with the
restore as with any delta: strokes added to a surviving page stay, and
anything on a page the restore removes is removed with it.

## 6. Identifiers and encodings

UUIDs are lowercase, hyphenated. Times are RFC 3339 `date-time` in years
0001 to 9999: `YYYY-MM-DDTHH:MM:SS`, an optional fraction of 1 to 9 digits
(readers keep milliseconds), then `Z` (writers) or `±HH:MM` (readers
accept). Writers emit milliseconds, `2026-10-04T16:20:00.123Z`. JSON writers
must not emit NaN or infinities, and refuse a value they cannot represent
(a date outside those years) rather than write a file readers cannot decode.
Numbers in `points` are plain JSON numbers.

## 7. Versioning

`format` in `vault.json` and the body version byte identify the format.
A reader that sees a higher major version must refuse to write and may
offer read-only access if it can parse the files.

Until the first tagged release the format is pre-1.0: it may change without
a version bump or a migration path. Throughout, readers reject a revision
holding an op type they do not know (fail closed, reported like any other
unreadable revision); they never silently drop the op and apply the rest.

## 8. Untrusted input

Everything in a vault folder may come from a hostile sync server, a shared
folder or a crafted import, and is untrusted until its age header, body tag
(§4) and content have been checked; even then a recipient may be malicious.
A reader must fail on bad input with an error it reports (§4, §5), never by
crashing, hanging, or allocating without a bound. Concretely, readers:

- reject a `seq` above 2^53 − 1 anywhere (§5) and a date that is not the
  RFC 3339 form of §6, including impossible ones (`02-30`, hour 24, second 60);
- treat sizes, counts and coordinates as claims to check against the bytes
  actually present before allocating for them;
- never follow a reference chain, nesting or `parent` link without a bound,
  and never expand shared references (a plist object used many times, an
  XML entity) into copies;
- bound the work a renderer or importer does by the size of its input, not
  by the distances, extents or counts the input names.

The reference implementation (`Sources/`) enforces these limits; other
readers may choose their own. Larger inputs fail with a typed error, except
where the table says how they degrade.

| What | Limit | Where |
| --- | --- | --- |
| revision file, sync state | 256 MiB on disk, 256 MiB after gunzip | `BoundedRead`, `Gzip.defaultMaxOutput` |
| `vault.json`, `rewrap-journal.json` | 16 MiB | `BoundedRead` |
| identity file, device state | 1 MiB | `BoundedRead` |
| files read at all | regular files only (no FIFOs or devices; symlinks followed in a vault, not in an imported package) | `BoundedRead` |
| JSON nesting | 512 levels (Foundation's decoder) | |
| `seq`, `included` `upTo` / `extra` | 1 … 2^53 − 1 | `RevisionName.maxSeq` |
| age header | 2 MiB, 1024 stanzas | Age `HeaderCodec` |
| scrypt work factor (identity files) | 2^20 by default (1 GiB), at most 2^22 | `IdentityFile` |
| WebDAV response | 256 MiB for a revision, 16 MiB otherwise; PROPFIND bodies must be UTF-8 with no DTD or processing instruction | `WebDAVClient` |
| zip entry (import) | 1 GiB uncompressed, CRC and size checked | `ZipArchive` |
| binary plist (import) | 64 levels; no cycles; each object parsed once; XML plists refused | `BinaryPlist` |
| keyed-archive UID chain | 64 hops | `KeyedArchive` |
| Notability coordinates and widths | ±10⁶ units, finite; recognised pages up to 100 000; dates outside 0001…9999 dropped (`.note` and `.ntb`) | `NotabilityNote` |
| `.ntb` bundle (import) | geometry, erase lists and titles decoded: 4 × the bundle's size + 64 KiB; pages below 100 000 | `NotabilityBundle.decodeBudgetFactor` |
| shape objects (import) | 1 curve point per byte of the `shapes` plist + 65 536 | `NotabilityShapes.pointsPerByte` |
| duplicate detection (import) | 256 stroke comparisons per stroke + 10⁶ per copy; beyond, the copy is imported as a separate version | `NotabilityImporter.PrintIndex` |
| page size and stroke extent (render) | 200 000 pt | `RenderLimits.maxExtent` |
| curve samples per stroke | 64 per control point + 1024 (sparser beyond) | `RenderLimits.samplesPerPoint` |
| outline points per page | 40 M | `RenderLimits.maxOutlinePoints` |
| nib width | 1 000 pt (drawn no wider) | `RenderLimits.maxNibWidth` |
| paper ruling | 40 000 commands per band, 1 M per page (plain background beyond) | `RenderLimits.maxPaperCommands…` |
| PNG image | 40 M pixels by default | `PNGOptions.maxPixels` |
| notebook levels shown | 64 | `NotebookNode.maxDepth` |

Foundation's own parsers are not safe on hostile bytes on every platform:
on Linux, `PropertyListSerialization` crashes on a binary plist holding a
set, `ISO8601DateFormatter` dies in ICU on a long fraction, and `XMLParser`
crashes on an element name that is not UTF-8 or on a processing
instruction without data. The library parses dates and binary plists
itself and checks PROPFIND bodies before `XMLParser` sees them.
`Tests/FuzzSupport` fuzzes every parser above on each test run.
