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
- `seq`: per (note, device) counter, decimal, starting at 1, gap-free.
  A writer chooses `seq` greater than every `seq` for its device that
  appears in a file name of the note or is covered by any snapshot's
  `included` (§5.3), so a seq whose file was compacted away is never reused.

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
| `setMeta` | `field`, `value` | LWW per field (§5.4); writers never set `tags` (§5.4.1) |
| `addTag` | `tag` | add one instance of a tag (§5.4.1) |
| `removeTag` | `tag`, `observed` | remove the listed instances of a tag (§5.4.1) |
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
inner whitespace runs collapsed (multi-word tags are fine): the **tag key**
of a tag is its whitespace-separated words joined by one space, then
lowercased (Unicode default case mapping). A note's tags are a set keyed by
tag key that merges per tag, not as one register (§5.4.1), so tags added on
two devices concurrently are both kept. Apps list a tag with one spelling
per key (§5.4.1). Titles are labels, never keys: any number of
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

`State` may carry `"clocks"`, mapping each LWW register (`title`, `tags`
(legacy, §5.4.1), `notebook`, `favorite`, `paper`, `pageSize`, `deleted`) to the stamp of the
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

#### 5.4.1 Tags: per-tag merge (observed-remove set, add wins)

A note's tags are an observed-remove set of **tag instances**. Each
`addTag` op adds one instance, identified by the op's origin
`"<hlc>-<device>-<seq>-<op>"` (§5.5) and belonging to the key of its `tag`.
A `removeTag` op removes exactly the instances it lists:

```json
{ "op": "addTag", "tag": "Math" }
{ "op": "removeTag", "tag": "math",
  "observed": ["17596320000000003-a1b2c3d4-12-4", "17596310000000000-99ee00ff-0-1"] }
```

- `addTag.tag`: the tag as written: whitespace runs collapsed to one space,
  trimmed, not empty. A writer adds a tag only when the note has no live
  instance of its key.
- `removeTag.tag`: any spelling of the key; `observed`: every live instance of
  that key the writer sees (a writer removes a tag by listing all of them).
  Instances of other keys are never affected, even if listed.
- A tag (key) is on the note while it has at least one live instance. An
  instance is live if some snapshot holds it or an uncovered delta adds it,
  unless any revision's `removeTag` (covered or not) or any snapshot's
  `removed` names it under its key, or a legacy write supersedes it (below).
  Removed instances are permanent, like page tombstones: a removed
  instance's add arriving late stays removed.

**Concurrent add and remove: add wins.** A remove only removes the instances
its writer had seen, so a tag added on another device that the remover had
not yet received survives, as does a re-add after a remove. This deliberately
differs from strokes (§5.2, remove wins): a stroke id is added once and never
again, so its remove covers its only add, whereas the same tag is added
again routinely, and silently losing a tag the user just added on the other
device is worse than a removal that has to be repeated. Per-key LWW on the
HLC was rejected for the same reason: with clock skew between devices (up to
the 24 hours §5 allows a clock to adopt), a remove could delete an add it
never saw.

**Spelling and order.** A key's spelling is the `tag` of its earliest live
instance by origin order `(hlc, device, seq, op)` (first-seen spelling,
deterministic on every device). Changing the spelling of a tag is a
`removeTag` of the key followed by an `addTag` with the new spelling, in one
delta. Tags are listed in the order of their keys' earliest live instances
(the order they were added).

**Legacy `setMeta` of `tags`.** Revisions written before this rule set the
whole array with `setMeta`, `field: "tags"`. Readers must still accept it;
writers must not emit it. All such writes still resolve as one LWW register
(§5.2, §5.4: the greatest stamp wins); let `L` be the winning array and `S`
its stamp. Then:

1. `L` is a baseline: for each key in `L` there is one instance with origin
   `"<hlc>-<device>-0-<i>"`, where `<hlc>-<device>` is `S` and `i` is the
   index in `L` of the key's first spelling, which is the instance's `tag`.
   Sequence number 0 never names a real revision, so baseline instances
   cannot collide with added ones. `removeTag` lists them like any instance.
2. `L` replaced the whole set at `S`: every other instance whose
   `(hlc, device)` is less than `S` is not live, whatever its key (the keys
   `L` lists live on as its baseline instances, with `L`'s spelling).
   Comparison is by `(hlc, device)` only, so per-tag ops in the same revision
   as a legacy write are never superseded by it.

So per-tag ops stamped after a legacy write apply on top of it, and a legacy
write (from a device not yet updated) still removes older tags it does not
list. A note that holds two spellings of one key in `L` has one tag with the
first spelling. Because the winning stamp only grows as revisions arrive, an
instance superseded under one legacy write is superseded under every later
winner too: it is never live again, so dropping it from a snapshot changes
nothing. (Rule 2 must not spare older instances of keys in `L`: a snapshot
written under an older winner would then keep that winner's baseline, or an
older instance, alive beside the newer baseline, and a remove written from
a view without that snapshot would not list it.)

**Snapshots.** A snapshot written under this rule carries the set in
`State`:

```json
"tagSet": {
  "instances": [ { "tag": "Math", "origin": "17596320000000003-a1b2c3d4-12-4" } ],
  "removed":   [ { "key": "fall", "origin": "17596310000000000-99ee00ff-0-1" } ],
  "legacy":    { "tags": ["math", "fall"], "clock": "17596310000000000-99ee00ff" }
}
```

- `instances`: every live instance, sorted by `origin`. Baseline instances
  (`seq` 0) are listed too, but readers ignore listed baselines and derive
  them from the winning legacy write (rule 1) alone.
- `removed`: every instance (key and origin) named by a `removeTag` or by an
  input snapshot's `removed`, sorted by `(origin, key)`; never pruned.
- `legacy`: the winning legacy register `L` and its stamp `S`; absent when
  no legacy write was ever seen.

`tagSet` is always present in such a snapshot (`instances` and `removed` may
be empty arrays). Its `meta.tags` then holds the resulting tags in display
order, for readers without this rule and for stock-CLI recovery; readers
with this rule ignore it and `clocks.tags` (writers omit the latter). A
snapshot without `tagSet` was written before this rule: its `meta.tags`, with
`clocks.tags` (or the snapshot's own stamp), is one legacy write.

Merging is still a union of commutative parts (instances, removals, the LWW
legacy register), so reconstruction stays order-independent (§5.3) and
correct through any compaction. Readers that do not know `addTag` and
`removeTag` reject revisions holding them (§7): such a reader must be
updated, not silently miss tags.

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
  recognition and metadata register that differs (except `tags`), and `deleteNote` or
  `restoreNote` if `deleted` differs;
- `removeTag` for every tag key present now but not as of R, `addTag` for
  every key present as of R but not now, and both for a key whose spelling
  differs (§5.4.1).

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

UUIDs are lowercase, hyphenated. Times are RFC 3339 UTC. JSON writers must
not emit NaN or infinities. Numbers in `points` are plain JSON numbers.

## 7. Versioning

`format` in `vault.json` and the body version byte identify the format.
A reader that sees a higher major version must refuse to write and may
offer read-only access if it can parse the files.

Until the first tagged release the format is pre-1.0: it may change without
a version bump or a migration path. Throughout, readers reject a revision
holding an op type they do not know (fail closed, reported like any other
unreadable revision); they never silently drop the op and apply the rest.
