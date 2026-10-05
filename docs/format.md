# InkVault on-disk format, version 1

Normative. Changes to this file are format changes and need a version bump
or a documented compatible extension.

## 1. Vault layout

A vault is a directory whose name ends in `.inkvault`.

```
Notes.inkvault/
  vault.json                              plaintext manifest (§2)
  keys/
    <key-name>.key.age                    optional passphrase-wrapped identity (§3.2)
  notes/
    <noteId>/
      <hlc>-<device>-<seq>.delta.age      append-only revision (§5)
      <hlc>-<device>-<seq>.snapshot.age   append-only snapshot  (§5)
      att/
        <blobName>.<kind>.age             the note's attachment bytes: images, PDFs, audio, transcripts (§8.1)
```

Everything under `notes/` (revisions and `att/` blobs alike) is written once
and never modified. The only exception is a recipient change (§3.3), which
rewrites files in place (and renames blobs, §8.1.5).

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

- `recipients[].key`: an age MLKEM768-X25519 recipient (§3.1, Bech32, HRP
  `age1pq`). At least one. Writers MUST NOT create a vault with, or add, an
  X25519 recipient (HRP `age`). A vault that lists any X25519 recipient
  (alone or next to MLKEM768-X25519 ones) is a **legacy vault**: it may be
  opened only to migrate it (§3.3.2).
- `vaultSecret`: 32 random bytes, age-encrypted and armored, to exactly the
  listed recipients. It keys the inner authentication tag (§4) and the blob
  names (§8.1.2), and nothing else. It is rotated whenever a recipient is
  removed.
- `features` (optional, *new: attachments*): array of strings naming format
  extensions the vault uses. A writer adds `"attachments"` before it writes
  the first blob or attachment op (§8). A writer that finds a feature it does
  not implement must not write to the vault (it may still read it, §7).
  Absent means `[]`.

## 3. Keys

### 3.1 Identity

An age native identity, exactly as the reference `age-keygen` produces it
(c2sp.org/age, "Native recipient types"). New keys are always
MLKEM768-X25519; X25519 identities exist only to migrate legacy vaults
(§3.3.2):

- **MLKEM768-X25519** (hybrid post-quantum, `age-keygen -pq`, age v1.3+): a
  32-byte seed, Bech32 with HRP `AGE-SECRET-KEY-PQ-` (77 characters). Its
  recipient is the 1216-byte X-Wing public key (ML-KEM-768 encapsulation key
  ‖ X25519 public key), Bech32 with HRP `age1pq` (1959 characters; the
  Bech32 90-character limit does not apply). Files to it carry one
  `mlkem768x25519` stanza: HPKE (RFC 9180) base mode with KEM
  MLKEM768-X25519 (0x647a, draft-ietf-hpke-pq-03, which is X-Wing,
  draft-connolly-cfrg-xwing-kem), HKDF-SHA256 and ChaCha20-Poly1305, `info`
  `age-encryption.org/mlkem768x25519`; the one argument is the base64 1120-byte
  encapsulation, the body the 32-byte sealed file key. Secure against
  "harvest now, decrypt later" by a future quantum computer, provided no
  stanza of another type sits next to it.
- **X25519** (classic, `age-keygen`, legacy vaults only): Bech32 with HRP
  `AGE-SECRET-KEY-`; recipient HRP `age`; one `X25519` stanza per recipient.

The corresponding recipient is derived from the identity. Reading files
encrypted to an MLKEM768-X25519 recipient with the stock CLI needs `age` 1.3
or later.

### 3.2 Passphrase-wrapped identity file

`keys/<key-name>.key.age` is an age file encrypted with a single scrypt
(passphrase) recipient. `<key-name>` is the recipient string for an X25519
key, and for an MLKEM768-X25519 key (whose recipient is too long for a file
name) `age1pq-` followed by the lowercase hex SHA-256 of the recipient string
(64 digits). Readers find such a file by computing the name for each
recipient in `vault.json`. Its plaintext is an `age-keygen` style file:

```
# created: 2026-10-04T16:20:00Z
# public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
AGE-SECRET-KEY-1QGFZ...
```

(for a post-quantum key the `# public key:` line holds the `age1pq1...`
recipient and the last line the `AGE-SECRET-KEY-PQ-1...` identity).

`age -d keys/<key-name>.key.age` with the passphrase must work. Writers
use an scrypt work factor between 15 and 18; readers must accept any work
factor up to 20, may accept up to 22, and may refuse larger with an error.
The reader cap exists because scrypt at work factor w needs 2^w × 1 KiB of
memory (20 → 1 GiB, 22 → 4 GiB), beyond what the iPad target can allocate.

The file is optional. A vault may be used with an identity that is only
in a device Keychain or supplied externally.

### 3.3 Changing recipients

Adding a recipient: append it to `recipients`, re-encrypt `vaultSecret`
to the new set, then re-encrypt every revision under `notes/` to the new set
(new file key and header), and rewrap every blob under `notes/<id>/att/`
(§8.1.5). Removing a recipient: the same, with a freshly generated
`vaultSecret`, which also renames every blob (§8.1.5). These are the only in-place
rewrites in the format; do them from one device while others are idle.

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
     "previousVaultSecret": "-----BEGIN AGE ENCRYPTED FILE-----\n...\n",
     "rekeyBlobs": true }
   ```

   - `format`: `inkvault/1`.
   - `previousVaultSecret`: present only when the secret is rotated
     (removal): the outgoing 32-byte vault secret, age-encrypted and
     armored to the **new** recipient set. Absent when adding.
   - `rekeyBlobs` (*new: attachments*, optional): how blobs are rewrapped
     (§8.1.5): `true` re-encrypts each under a new file key, `false` rewrites
     only its header. Absent means the default policy of §8.1.5. A device
     finishing an interrupted change uses the recorded value.
2. Write `vault.json` with the new `recipients` and `vaultSecret`.
3. For every file under `notes/` (revisions and `att/` blobs), skip it if it is already
   complete (below); otherwise rewrite it as described above, verifying its
   tag under the current secret or, failing that, under
   `previousVaultSecret`, and replace it atomically (temporary file in the
   same directory, then rename; blobs: §8.1.5).
4. Delete `rewrap-journal.json` once every file is complete. If any file
   could not be read or verified, keep the journal (it is the only copy of
   the outgoing secret), report those files, and retry step 3 later.

A file is complete when its age header has, for each stanza type, exactly
one stanza per current recipient of the matching type (`X25519` for `age1`
recipients, `mlkem768x25519` for `age1pq1` recipients) and no other stanzas,
and its tag verifies under the current `vaultSecret` (for a blob: its name
verifies, §8.1.5). Neither stanza type names its recipient, so these counts
are the only header-level check; while a journal exists no other recipient
change is started, so counts from two changes never mix.

If `rewrap-journal.json` exists when a vault is opened, the change is
unfinished: a writer finishes steps 3 and 4 before any other recipient
change, and may verify tags under `previousVaultSecret` meanwhile. Readers
that do not implement this procedure treat the journal as an unknown file
(§1).

A change may also **replace** one recipient by another in a single pass
(steps 1–4 as for a removal: the secret rotates). Until it finishes, files
not yet rewrapped are encrypted only to the outgoing recipient, so finishing
it needs an identity of the outgoing key as well as one of the new set.

#### 3.3.2 Migrating legacy X25519 vaults

A vault whose `recipients` include an X25519 key (HRP `age`), alone or next
to MLKEM768-X25519 keys, is a legacy vault. Implementations MUST NOT read or
write note content of a legacy vault (decrypt, list, show, search, export,
edit, import, compact, snapshot, restore, or verify revision files): they
MUST refuse and direct the user to migrate. They MAY open and unlock it,
read `vault.json` and the `keys/` files, and perform the migration below
(including finishing an interrupted one per §3.3.1). The on-disk format of a
legacy vault is unchanged, so the stock-CLI recovery of §4 still works on
it; this rule binds implementations, not `age`. Once no X25519 recipient is
listed the vault is an ordinary vault again (an unfinished rewrap is then
finished as in §3.3.1).

All files of a vault are quantum-safe only once every recipient is
MLKEM768-X25519: an `X25519` stanza next to an `mlkem768x25519` one lets a
quantum adversary recover the file key. Writers encrypt every file (and
`vaultSecret`) to the full recipient list, so a legacy vault that has gained
a post-quantum recipient but still lists an X25519 one writes files with
both stanza types. The spec says files SHOULD NOT mix them and `age` refuses
to encrypt such a mix, but `age` 1.3+ decrypts them; the format allows the
mix only during this migration.

To migrate, generate an MLKEM768-X25519 identity per device, then either

1. **replace** each X25519 recipient by its post-quantum successor (§3.3.1,
   one rewrap per key, no file ever mixed), or
2. **add** every post-quantum recipient, then **remove** every X25519
   recipient (several devices can switch one at a time; files are mixed in
   between).

Either way the rewrap gives every file a fresh file key, and the removal or
replacement rotates `vaultSecret`, whose X25519-encrypted copy was exposed.
Copies of files made before the rewrap (backups, iCloud Drive or other
file-provider version history, sync conflict copies) are still X25519-only
and stay exposed to "harvest now, decrypt later"; the format cannot reach them.

## 4. Encrypted file bodies

Every revision file (`notes/<noteId>/*.age`) is an age v1 file whose
plaintext is (blobs in `att/` use their own framing, §8.1.3):

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

With a post-quantum key (`AGE-SECRET-KEY-PQ-1...`) this needs `age` 1.3 or
later; older `age` reports that no identity matched.

## 5. Revisions

Each file directly under `notes/<noteId>/` is one revision. The `att/`
subdirectory (*new: attachments*) holds the note's blobs (§8.1); it is not a
revision and revision listings skip it. Name:

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
| `setMeta` | `field`, `value` | LWW per field (§5.4) |
| `deleteNote` | | LWW with `restoreNote` on `deleted` |
| `restoreNote` | | |
| `addItem` | `page`, `item` | *new: attachments.* Add a placed item (§8.2) to the page (no-op if page removed) |
| `removeItem` | `page`, `itemId` | *new.* Remove the item; wins over any add; permanent tombstone |
| `setItem` | `page`, `itemId`, `field`, `value` | *new.* LWW per (item, field) on the item's registers (§8.2.2) |
| `addRecording` | `recording` | *new.* Add an audio recording to the note (§8.3) |
| `removeRecording` | `recordingId` | *new.* Remove it; wins over any add; permanent tombstone |
| `setRecording` | `recordingId`, `field`, `value` | *new.* LWW per (recording, field) (§8.3) |

The LWW timestamp of an op is the revision's `(hlc, device)`. `addPage`
adds the page empty; strokes go in `addStroke` ops and items in `addItem`
ops. A stroke id is never added again after it has been removed; a writer
that undoes an erase, or restores from history, must mint a new id and may
set `parent` to the old one. The same holds for page, item and recording
ids.

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
an `addStroke`, `setPageOrder`, `setPageRecognition`, `addItem` or `setItem`
naming a page the writer has not seen, a `setItem` naming an item it has not
seen, or a `setRecording` naming a recording it has not seen, is left out,
so it is applied again once the page, item or recording arrives. An id the
writer knows only from a tombstone counts as seen (the op is a no-op).
(Removals of unseen ids are recorded as tombstones instead, §5.4.)

Readers reconstruct a note as the merge of every snapshot present plus every
delta not covered by any snapshot's `included`. Pages, strokes, placed items
(§8.2) and recordings (§8.3) merge as sets: an element is present if some
snapshot holds it or an uncovered delta adds it, unless a tombstone or an
uncovered remove names it, its page is gone, or some snapshot covers the
revision in its `origin` (§5.5, §5.6) but does not hold it. Metadata, page
order, item and recording registers and `deleted` merge by LWW, using each
snapshot's recorded clocks and each delta op's own timestamp.
Reconstruction is order-independent: the same set of revisions gives the
same state whatever order they are read in, and implementations must have a
test that reconstructs from shuffled revision orders and compares.

A device may write a snapshot at any time. A delta may be deleted when at
least one snapshot covers it and it is older than the retention window
(default 30 days by `wall`). A snapshot may be deleted when another
snapshot's `included` is a superset of its `included` and it is older than
the window; of two snapshots with equal `included`, keep at least one.
Compaction never deletes blobs; they have their own per-note collection rule
(§8.1.6).

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
  "pages": [ Page, ... ],
  "recordings": [ Recording, ... ]
}
```

`recordings` (*new: attachments*, §8.3) is omitted when empty and sorted by
`(started, id)`.

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

`State` may carry `"tombstones": {"strokes": [uuid, ...], "pages": [uuid, ...],
"items": [uuid, ...], "recordings": [uuid, ...]}`.
A delta adding a tombstoned id stays removed. `strokes` lists ids whose
`removeStroke` was seen while the revision that added the stroke was not yet
covered by `included`; once it is covered, the tombstone may be dropped.
`pages` lists every removed page id and is never pruned, so a late op on a
removed page is a no-op rather than an orphan (§5.3). `items` and
`recordings` (*new: attachments*) list every removed item and recording id
and are never pruned either, for the same reason (`setItem`,
`setRecording`). All fields are omitted when empty.

### 5.5 Page

```json
{ "id": "…", "order": "a0", "strokes": [ Stroke, ... ], "items": [ Item, ... ],
  "recognition": Recognition, "parent": "…" }
```

`items` (*new: attachments*) are the page's placed items (§8.2): text boxes,
images and PDF page backgrounds, sorted by `(layer, z, id)` (§8.2.3);
omitted when empty. `addPage` ignores any `items` in its page
object (the page is added empty). `recognition` is optional (below).
`parent` is optional: the id of a removed page this one re-creates (a restore from history, §5.7). It is
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
  "parent": "…",
  "rec": { "id": "…", "at": 754.125 }
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
- `rec` (optional, *new: attachments*): the stroke was drawn while recording
  `id` (§8.3) was running, starting `at` seconds after the recording began
  (§8.3.3). Set by `addStroke`, never changed; pieces sliced from a stroke
  copy it.
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

- pages, strokes, items and recordings present now but not as of R:
  `removePage` / `removeStroke` / `removeItem` / `removeRecording`;
- pages, strokes, items and recordings present as of R but removed since:
  re-added under new ids (`addPage`, `addStroke`, `addItem`, `addRecording`;
  a re-added page gets its strokes, items and recognition from R, a re-added
  item or recording its register values as of R), with `parent` set to the
  old id (§5.2);
- `setPageOrder`, `setPageRecognition`, `setItem`, `setRecording`,
  `setMeta` for every page order, recognition, item or recording register
  and metadata register that differs, and `deleteNote` or `restoreNote` if
  `deleted` differs.

A page, stroke, item or recording counts as present when its id is, or when
one with `parent` naming it is (for a stroke, also with the same `ink`,
`points` and `transform`; for an item or recording, also with the same
immutable fields, §8.2.2), so restoring the same point twice writes nothing
the second time. Restoring never needs a blob the vault has deleted: a blob
referenced by any surviving revision of its note is never collected (§8.1.6). The delta's `hlc` is issued after observing every revision of the
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

*New: attachments.* Inside the item and recording ops the format is open,
so new item kinds and fields can be added without a version bump:

- An item whose `kind` a reader does not know is kept: it merges like any
  item (its common fields, §8.2.1, must be valid or the revision is
  rejected), its JSON object is carried into snapshots unchanged, and
  renderers draw a placeholder in its frame (§8.5) and report it.
- A field a reader does not know, on an item, a recording, a text run or a
  blob reference, is kept and re-emitted unchanged when the object is
  written into a snapshot. A `setItem` or `setRecording` naming a field the
  reader does not know is an LWW register on that field like any other.
- A blob `type` a reader does not know is kept; the blob is still stored,
  synced, verified and collected, it is just not rendered or played.
- An item `layer` value without a defined meaning is ordered by its number
  (§8.2.3).

A future change that older readers must not merge blindly (new merge
semantics, not just a new kind of placed content) still needs a new op type,
so that older readers fail closed, or a `features` entry (§2), so that older
writers stay read-only.

## 8. Attachments

*New: attachments.* Typed text boxes, images, PDF page backgrounds and audio
recordings with transcripts. The rationale, the alternatives considered and
the implementation plan are in `docs/attachments.md`; this section is the
normative part. Small, mutable data (text, geometry, titles) lives in the
note's revisions like everything else; large, immutable bytes (images, PDFs,
audio, transcripts) live in *blobs* in the note's own `att/` folder, which
revisions reference by content hash.

### 8.1 Blobs

#### 8.1.1 Blob references

Revisions name a blob with a *blob reference*:

```json
{ "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "size": 482113, "type": "image/jpeg" }
```

- `sha256`: SHA-256 of the blob's content (the JPEG, PNG, PDF, audio or
  transcript file itself), 64 lowercase hex digits.
- `size`: the content's length in bytes.
- `type`: its media type. Defined: `image/jpeg`, `image/png`, `image/heic`
  (§8.2.5), `application/pdf` (§8.2.6), `audio/mp4` (§8.3.1),
  `application/vnd.inkvault.transcript+json` (§8.3.2). Others are kept (§7).

Every blob reference in a revision is a JSON object with these three keys
(and possibly unknown ones, §7); no other object in a revision body has a
`sha256` key. Collection (§8.1.6) relies on this to find references inside
item kinds and fields it does not know.

A reference resolves only inside the note that holds the revision: the blob
is `notes/<noteId>/att/…` of that note (§8.1.2). Within one note the same
content is one blob however many items use it. Another note that uses the
same content has its own copy (§8.1.4).

#### 8.1.2 Names

A blob of note `noteId` is stored as
`notes/<noteId>/att/<blobName>.<kind>.age`, where

```
blobName = lowercase hex of HMAC-SHA256(key = vaultSecret,
             message = "inkvault/1" ‖ 0x00 ‖ "blob" ‖ 0x00 ‖ sha256)
```

and `sha256` is the content hash as 32 raw bytes. Names are 64 hex digits.
They are keyed so that storage never shows a plaintext content hash: anyone
could otherwise confirm that a vault holds a known file by hashing it. The
name doubles as the blob's authentication tag: only a holder of the vault
secret can produce the name that matches a content hash, and a reader checks
it (§8.1.4). There is no tag inside the blob, so a secret rotation renames
blobs instead of re-encrypting them (§8.1.5). The name does not depend on the
note, so a blob file copied byte for byte into another note's `att/` is valid
there.

`kind` is derived from the reference's `type`:

| `type` | `kind` |
| --- | --- |
| `image/*` | `image` |
| `application/pdf` | `pdf` |
| `audio/*` | `audio` |
| `video/*` | `video` (reserved, §8.2.7) |
| `application/vnd.inkvault.transcript+json` | `transcript` |
| anything else | `bin` |

A reader looks a blob up by the path computed from the reference; it never
guesses another kind. The kind is visible to storage on purpose (sync and the
app fetch images and PDFs when a note opens, audio only when it plays;
`docs/attachments.md` §2).

Entries in `att/` whose name is not 64 lowercase hex digits, `.`, a kind
(1–16 lowercase ASCII letters or digits) and `.age` are unknown files (§1).
Revision listings (§5) never look inside `att/`.

#### 8.1.3 Framing

A blob file is a binary age v1 file, encrypted to the vault's recipients like
a revision. Its plaintext is:

| Offset | Size | Content |
| --- | --- | --- |
| 0 | 4 | ASCII `INKB` |
| 4 | 1 | blob version, `0x01` |
| 5 | 32 | SHA-256 of the content (raw) |
| 37 | 8 | content length `L`, unsigned big-endian |
| 45 | `L` | content, exactly as referenced (not compressed) |
| 45 + `L` | rest | padding: zero bytes |

Writers should pad the plaintext to `padme(45 + L)` bytes, which hides the
exact content length (a known file is otherwise recognisable by its size)
for at most 12 % overhead, less for large blobs:

```
padme(n) = n                                  if n < 2
           E = floor(log2 n), S = floor(log2 E) + 1, z = E − S,
           ((n + 2^z − 1) >> z) << z          otherwise
```

Readers accept any amount of padding but reject non-zero padding bytes.

Test vector: vault secret bytes `00 01 02 … 1f`, content the 16 ASCII bytes
`hello, inkvault\n`, type `text/plain` (kind `bin`):

```
sha256    b023506dad39637be6e6e2ec3a0c31f8c0af3fe9bc060be0223b789cb75e5c00
blobName  634be1aa11f40878a731812e96fb37920e7b9a3272f392a133a1bbc831c3d1b2
path      notes/<noteId>/att/634be1aa…d1b2.bin.age
header    494e4b4201 b023…5c00 0000000000000010   (45 bytes)
padme     61 → 64 (3 zero bytes); 1000 → 1024; 482158 → 483328; 28311597 → 28835840
```

#### 8.1.4 Writing and reading

A writer that adds content to note N:

1. hashes the content and derives `blobName` and the path in N's `att/`;
2. if that file exists and its first STREAM chunk decrypts to a valid header
   (magic, version, the same `sha256`, a name that verifies), reuses it; if
   it exists but fails that check, may replace it atomically with a valid
   encryption (the only replacement of a blob outside §8.1.5);
3. otherwise writes it with the atomic-write procedure (`docs/io.md`),
   never replacing an existing file of that name;
4. only after the blob is durable, writes the revision that references it.

Copying or moving an item to another note M (copy and paste, "move to
note", duplicating a note) writes the blob into M's `att/` by steps 1–4 for
M; a byte copy of N's blob file is a valid way to do step 3. A writer never
writes a reference in M that relies on a blob of N.

A blob is valid when its framing is well formed, `L` and the content fit the
file, the padding is zero, the SHA-256 of the content equals the header's,
and `blobName` computed from the header's hash under the vault secret equals
its file name. Read through a reference, the header's hash and `L` must also
equal the reference's `sha256` and `size`. Readers must check the name when
the vault secret is available and must always check the content hash. A
reader that hands out content before the hash is complete (streaming audio,
a large PDF) must stop and report on a mismatch. Failures are reported like
unreadable revisions and the blob is treated as missing (§8.5.2).

Blobs are processed as streams: age's STREAM payload is authenticated in
64 KiB chunks, so readers and writers need memory proportional to a chunk,
not to the blob. Implementations may hold a blob of at most 16 MiB in memory
whole; larger blobs must be streamed (to a private temporary file where
random access is needed, e.g. reading a PDF, deleted when done).

#### 8.1.5 Recipient changes

The recipients of a vault are its **device keys**: one age recipient per
device (or paper backup key) that may open the vault (§2, §3). Adding a
recipient means letting a new device open the vault; removing one means
locking out a lost or retired device. Recipients have nothing to do with
sharing a note with another person: that is an export (PDF, SVG, PNG, or a
copy), never a change of recipients.

The procedure of §3.3.1 covers blobs. A blob is complete when its age header
has exactly one recipient stanza per current recipient, of that recipient's
type (and no others), and its name verifies under the current `vaultSecret`
using the hash in its header (only the first STREAM chunk needs decrypting).

A blob is rewrapped in one of two ways:

- **Header-only rewrite** (keep the file key): a new age header (one stanza
  per current recipient wrapping the same file key, new header MAC) followed
  by the unchanged nonce and payload bytes.
- **Full re-encryption** (new file key): the content is decrypted and
  encrypted again under a fresh file key and nonce.

Default policy, chosen automatically by the kind of change:

| Change | Default | Why |
| --- | --- | --- |
| a recipient is added (and none removed) | header-only rewrite | everyone who could read a blob still can; nothing becomes readable to anyone who could not read it before |
| a recipient is removed | full re-encryption | every old copy of a blob's header (backups, file-version history, another device's cache) has a stanza the removed key opens; with the same file key it would open the current file too |
| the recipients' type changes (classic X25519 to the post-quantum hybrid) | full re-encryption | an old header's classic stanza stays breakable later; with the same file key it would open the post-quantum file too |

A change that both adds and removes follows the removal row. Implementations
may let the user choose the other method for each of the two cases (adding;
removing or changing type); the default is the table above. The method in
force is written to `rewrap-journal.json` as `rekeyBlobs` (§3.3.1) before the
first blob is rewritten. Revisions are always fully re-encrypted (§3.3).

On a recipient addition the name is unchanged and the file is replaced
atomically. On a removal the vault secret changes and so does the name: the
writer writes the rewrapped file under the new name in the same `att/`
(atomically, never replacing an existing valid file) and then deletes the old
one; if a valid file already exists under the new name (an interrupted run),
it only deletes the old one. A blob whose name verifies under neither the
current secret nor `previousVaultSecret` is left untouched and reported,
never rewrapped or renamed, so a rewrap cannot launder a planted file. While
`rewrap-journal.json` exists, a reader looking up a reference tries the name
under the current secret, then under `previousVaultSecret`.

#### 8.1.6 Collection

Compaction (§5.3) never deletes a blob. Blobs are collected **per note**: a
blob in `notes/<N>/att/` may be deleted only when all of these hold:

1. every revision file of note N was listed, read and verified (one
   unreadable or unlistable revision of N stops collection for N: it may
   hold the only reference);
2. no `rewrap-journal.json` exists;
3. no revision of N present, snapshot or delta, contains a blob reference
   (§8.1.1) with the blob's content hash (a deleted note, §5.2, still has
   its revisions, so its blobs stay);
4. the collecting device found 1–3 true for this blob at least the retention
   window (§5.3, default 30 days) ago, and has found it unreferenced every
   time it looked since. It records this in its own device-local state,
   never in the vault.

No other note is read: references never cross notes (§8.1.1). Blob files
that cannot be decrypted or verified are never deleted by collection; they
are reported. Because every surviving revision keeps its blobs, history
(§5.7) never loses an attachment that a restore point needs.

Rule 4 covers a device that reuses a blob (§8.1.4 step 2) while another
collects it: the reference must stay unsynced for longer than the window to
be left dangling. A reader that finds a referenced blob missing reports it
and draws a placeholder (§8.5.2); a writer that still holds the content
should write it again.

A sync tool deletes a blob on one side because the other side dropped it only
if rules 1–3 hold for its note on the side it deletes from (as it does for
compacted revisions, `docs/io.md`).

#### 8.1.7 Recovery without the app

```
B=notes/NOTE/att/NAME.KIND.age
age -d -i key.txt "$B" | head -c 37 | tail -c 32 | xxd -p -c 32   # content sha256
age -d -i key.txt "$B" | head -c 45 | tail -c 8  | xxd -p         # L, hex
age -d -i key.txt "$B" | tail -c +46 | head -c "$((16#<L hex>))" > out
```

The content hash matches the `sha256` of the item or recording that uses the
blob (readable from any revision of the same note, §4); `KIND` and
`file out` tell the type. Without `head -c` the output carries the zero
padding after the content.

### 8.2 Placed items

A page's `items` (§5.5) are text boxes, images and PDF page backgrounds,
placed in page coordinates (points, origin top-left, y down).

#### 8.2.1 Common fields

```json
{
  "id": "6f1c2d4e-…",
  "kind": "image",
  "layer": 100,
  "frame": [72, 144, 288, 216],
  "rotation": 0,
  "z": "a0",
  "parent": "…",
  "rec": { "id": "…", "at": 12.5 },
  "origin": "17596320000000003-a1b2c3d4-12-4",
  "clocks": { "frame": "17596320000000003-a1b2c3d4" }
}
```

plus the fields of its kind (§8.2.4–§8.2.7).

- `id`: UUID.
- `kind`: `text`, `image` or `pdfPage`; `math` and `video` are reserved
  (§8.2.7); others per §7.
- `layer`: integer z-layer, 0 to 65 535 (§8.2.3). Defined: `0` background,
  `100` content. Absent means `100`. Writers write only defined values;
  readers order by any value in range and treat a value out of range or not
  an integer as `100`.
- `frame`: `[x, y, w, h]`, the item's box before rotation; `w` and `h` > 0.
- `rotation`: degrees, clockwise about the frame's centre; absent means 0.
- `z`: order key within the layer, compared like page `order` (§5.5).
- `parent`: optional, the item this one replaces (moved to another page or
  note, restored from history).
- `rec`: optional, as on strokes (§5.6, §8.3.3).
- `origin`: snapshots only, as on strokes (§5.5).
- `clocks`: snapshots only, maps each register (§8.2.2) to the
  `"<hlc>-<device>"` stamp of the op that last set it; a register without a
  clock is stamped by the snapshot's own `(hlc, device)`.

Numbers are rounded to at most 3 decimals by writers.

#### 8.2.2 Registers, ops and merge

Every field an item has is either a *register*, changed with `setItem` and
merged last-writer-wins per (item, field), or *immutable*, set by `addItem`
and never changed.

| Kind | Registers | Immutable |
| --- | --- | --- |
| every kind | `frame`, `rotation`, `z` | `id`, `kind`, `layer`, `parent`, `rec` |
| `text` | `text` | |
| `image` | `crop` | `blob`, `pixelSize`, `orientation` |
| `pdfPage` | `crop` | `blob`, `pageIndex`, `pageSize` |

- `addItem` sets every field; its register values carry the op's stamp.
- `setItem` with `field` naming an immutable field is invalid (the revision
  is rejected). `value: null` resets an optional register (`rotation`,
  `crop`) to absent; `null` for `frame`, `z` or `text` is invalid. A field
  the reader does not know is a register (§7).
- `setItem` on a removed item, or an item on a removed page, is a no-op.
- Items merge as sets like strokes (§5.3), with permanent tombstones (§5.4).
  An item belongs to one page; moving it to another page is `removeItem`
  plus `addItem` of a new id with `parent` naming the old one (to another
  note: the same, with the blob copied first, §8.1.4).

Concurrent moves, resizes and text edits of one item therefore keep the last
writer's value per field; the other is still in history (§5.7).

#### 8.2.3 Layers and drawing order

A page is drawn, bottom to top:

1. the paper background colour (§5.4);
2. the paper ruling;
3. items by `(layer, z, id)`: lower layers first, then by `z`, then by `id`.
   An item whose `layer` is below 100 (a background layer) first fills its
   frame (rotated) with the paper background colour, so ruling never shows
   through it;
4. strokes, by `origin` (§5.5).

Ink is drawn above every item, whatever its layer. Layers other than 0 and
100 have no defined meaning yet; a later format change may give some of them
one (for example a layer above the ink) without changing how existing items
are stored. `image` and `pdfPage` items are clipped to their frame; text is
not. An exporter that leaves out the paper also leaves out the fill of
step 3. For an infinite page, items count toward the extent like strokes
(their rotated frame's lowest point), and an item crossing a break is cut
across export pages like a stroke.

#### 8.2.4 Text

```json
{ "kind": "text", "layer": 100, "frame": [72, 90, 300, 40], "z": "a1",
  "text": {
    "font": "sans", "family": "SF Pro", "size": 12, "color": "#1A1A1AFF",
    "align": "start", "dir": "auto", "lang": "en",
    "runs": [ { "t": "Lecture 3", "b": true, "size": 18 },
              { "t": "\nlinear maps and their kernels" } ],
    "breaks": [] } }
```

- `font`: `sans`, `serif` or `mono` (unknown values are `sans`): the generic
  family. Every renderer maps it to fonts it has (§8.5.3).
- `family`: optional, informational: the concrete family the writer laid the
  text out with (e.g. `SF Pro`, `Noto Sans`).
- `size`: points, greater than 0 and at most 1000. `color`: `#RRGGBBAA`.
- `align`: `start`, `center`, `end`, `left` or `right` (unknown values and
  absent are `start`). `start` and `end` follow each paragraph's direction.
- `dir`: `auto`, `ltr` or `rtl` (unknown and absent are `auto`): the
  paragraph direction. `auto` takes each paragraph's direction from its first
  strong character (Unicode bidirectional algorithm, UAX #9, rules P2–P3),
  left to right if it has none.
- `lang`: optional BCP 47 tag of the text's language; a run may override it.
  Renderers use it to choose fonts (Chinese, Japanese and Korean share code
  points but not glyph shapes).
- `runs`: the text, possibly empty. Each run has `t` (the run's text, any
  Unicode scalar values except C0 controls other than `\n` and `\t`) and
  optionally `b` (bold), `i` (italic), `u` (underline), `s`
  (strikethrough), all `false` when absent, and `color`, `size` and `lang`,
  which override the box's. The item's text is the concatenation of every
  `t` in logical (typing) order; `\n` is a hard line break (writers store no
  other line terminator). Writers store text in NFC and merge adjacent runs
  with equal attributes.
- `breaks`: optional, the writer's soft line breaks: strictly increasing
  offsets, in Unicode scalar values from the start of the item's text, at
  which a new line starts that is not after a `\n`. Writers that lay text out
  should store it; renderers use it (§8.5.3).
- `frame` width is the wrapping width. `frame` height is the height the
  writer laid the text out to; renderers never clip text to it (§8.5.3).

The whole `text` object is one register: concurrent edits do not merge
character by character, and `breaks` always belongs to the text it was
computed for. The item's text is part of the page's searchable text, beside
`recognition` (§5.5); it is never copied into `recognition`.

#### 8.2.5 Image

```json
{ "kind": "image", "layer": 100, "frame": [72, 144, 216, 288], "z": "a0",
  "blob": { "sha256": "…", "size": 482113, "type": "image/jpeg" },
  "pixelSize": [3024, 4032], "orientation": 6, "crop": [0, 0, 3024, 4032] }
```

- `blob`: `image/jpeg` (baseline or progressive Huffman coding, 8 bits, one
  or three components; not CMYK, not arithmetic-coded), `image/png` (any
  valid PNG) or `image/heic`. Writers convert anything else (WebP, GIF,
  TIFF, CMYK JPEG) to JPEG or PNG, and should convert HEIC too unless the
  user chose to keep it (`docs/attachments.md` §7); a renderer that cannot
  decode HEIC draws a placeholder (§8.5.2).
- Metadata: unless the user chose to keep it, writers strip metadata from
  the stored bytes: in a JPEG every APPn segment except APP0 (JFIF), APP2
  (ICC profile) and APP14 (Adobe), and COM segments; in a PNG every
  ancillary chunk except `tRNS`, `gAMA`, `cHRM`, `sRGB`, `iCCP` and `pHYs`;
  in a HEIC the `Exif` and XMP items. Exporters strip the same metadata from
  bytes they pass through into an export unless asked to keep it, whatever
  is stored (a photo's location must not travel with a shared PDF).
- `orientation`: EXIF orientation, 1–8; absent means 1. Renderers apply this
  field and ignore any orientation stored in the image data.
- `pixelSize`: `[w, h]` after orientation, for layout before decoding.
  Renderers use the decoded size.
- `crop`: `[x, y, w, h]` in oriented pixel coordinates; absent means the
  whole image. Renderers intersect it with the image.

The crop rectangle is drawn onto the frame (§8.5.1). Writers keep the frame's
aspect ratio equal to the crop's; renderers scale the axes independently.

#### 8.2.6 PDF page

```json
{ "kind": "pdfPage", "layer": 0, "frame": [0, 0, 612, 792], "z": "a0",
  "blob": { "sha256": "…", "size": 1830221, "type": "application/pdf" },
  "pageIndex": 3, "pageSize": [612, 792], "crop": [36, 36, 540, 720] }
```

- `blob`: a PDF (versions 1.0–2.0) without encryption (no `/Encrypt` in the
  trailer). Writers remove encryption or refuse the file.
- `pageIndex`: 0-based index of the page in page-tree order.
- The *effective page* is the page's CropBox (inherited; default the
  MediaBox) intersected with its MediaBox, turned clockwise by its `/Rotate`
  (inherited; normalised to 0, 90, 180 or 270). It is a `W' × H'` rectangle
  in points, origin top-left, y down (§8.5.1).
- `pageSize`: `[W', H']`, informational: renderers that parse the PDF use its
  own boxes; others use it for layout and placeholders.
- `crop`: `[x, y, w, h]` on the effective page; absent means all of it.
- `layer` is `0` (background) for a page being annotated; `100` (content)
  places a page as a figure.

The crop rectangle is drawn onto the frame (§8.5.1). The PDF's annotations
(`/Annots`) are not drawn; a writer that wants them flattens them into the
PDF before storing it. Within a note one PDF blob serves any number of
`pdfPage` items. How a writer lays pages out (one note page per PDF page, or
bands of an infinite page) is its choice (`docs/attachments.md`).

#### 8.2.7 Reserved kinds

These kind names are reserved for planned features (`docs/attachments.md`
§14, tasks G1 and G2) and are not defined yet. Writers must not write them
until this section defines them; readers treat them as unknown kinds (§7),
drawing a placeholder.

- `math`: an equation, edited as LaTeX source and drawn typeset. Planned
  fields: `latex` (register, the source), `display` (register, display or
  inline style), `size` and `color` as for text, and `render` (register, a
  blob reference to a one-page PDF of the typeset result, so renderers
  without a math typesetter still draw it).
- `video`: a video clip on the page. Planned fields: `blob` (`video/mp4` or
  `video/quicktime`, kind `video`, within the blob limit of §8.4),
  `poster` (an image blob reference drawn in the frame), `duration`, and
  `rec`-style links as for audio.

### 8.3 Recordings

#### 8.3.1 Recording

A recording belongs to the note, not to a page (`recordings`, §5.4):

```json
{ "id": "…",
  "blob": { "sha256": "…", "size": 28311552, "type": "audio/mp4" },
  "started": "2026-10-04T16:20:00.000Z",
  "duration": 3540.25,
  "codec": "aac", "sampleRate": 48000, "channels": 1, "bitRate": 64000,
  "title": "Lecture 3",
  "transcript": { "sha256": "…", "size": 52011,
                  "type": "application/vnd.inkvault.transcript+json" },
  "parent": "…", "origin": "…", "clocks": { "title": "…" } }
```

- `blob`: the audio. Writers write `audio/mp4`: an MPEG-4 file with one audio
  track coded as AAC-LC (`codec: "aac"`), HE-AAC (`"he-aac"`) or ALAC
  (`"alac"`). Readers that play audio must support AAC-LC and should support
  the other two. The recording settings (codec, bit rate, sample rate,
  channels) are the user's choice; the default is AAC-LC, mono, 48 kHz,
  64 kbit/s (`docs/attachments.md` §9). Other types (from importers) are
  allowed and may be unplayable.
- `started`: RFC 3339 wall time of the first sample (sorting, display).
- `duration` (seconds, 3 decimals), `codec`, `sampleRate`, `channels`,
  `bitRate` (bits per second, average): informational.
- Registers: `title` (string; absent means `""`) and `transcript` (a blob
  reference or `null`), changed with `setRecording` and merged LWW per
  (recording, field) like item registers (§8.2.2), with `clocks` in
  snapshots. Every other field is immutable. Unknown fields as in §7.
- Recordings merge as sets like items, with permanent tombstones (§5.4).

#### 8.3.2 Transcript

A transcript is a blob whose content is UTF-8 JSON (not compressed):

```json
{ "format": "inkvault-transcript/1",
  "recording": "<recording id>",
  "engine": "apple-speechtranscriber-26.4",
  "language": "en-US",
  "created": "2026-10-04T17:21:00Z",
  "segments": [
    { "start": 0.52, "end": 3.1, "text": "Today we look at linear maps.",
      "confidence": 0.94,
      "words": [ { "t": "Today", "start": 0.52, "end": 0.8, "c": 0.97 },
                 { "t": "we", "start": 0.8, "end": 0.93, "c": 0.91 } ] } ] }
```

- `recording`: must be the id of the recording whose `transcript` register
  holds it; readers ignore and report a transcript naming another one.
- `engine`: name and version of the speech recogniser, as for recognition
  (§5.5), e.g. `apple-speechtranscriber-26.4`, `apple-sfspeech-26.7`,
  `notability-<version>`. `language`: BCP 47 tag of the language recognised; a
  segment may carry its own `language` when it differs.
- `created`: when the transcript was produced (RFC 3339).
- `segments`: time-stamped pieces of text (a phrase or sentence), sorted by
  `start`, not overlapping. Each has `start` and `end` (seconds from the
  start of the recording, 3 decimals, `start ≤ end`), `text`, and optional
  `confidence` (0…1, the recogniser's confidence in the segment).
- `words`: optional, per segment: the segment's words in order, each with
  `t` (the word as it appears in `text`), `start`, `end` (as for segments,
  within the segment's range) and optional `c` (confidence 0…1). A segment
  has all its words or none.

Segments are what search and the transcript view use; word timings let a
player highlight each word as it is read back and seek from a tapped word,
and word confidences let a viewer mark doubtful words (for example underline
words under 0.5) or let search skip them. A transcript is derived data,
replaced as a whole by `setRecording` of `transcript`, never merged. Readers
that index text for search include it.

#### 8.3.3 Ink and audio

In plain words: while a recording is running, everything written or placed
on the page is stamped with *which* recording was running and *how many
seconds* into it the writing happened. Tapping that ink later plays the audio
from that moment, and playing the recording can show the ink appearing as it
was written.

Precisely: a stroke or item drawn, typed or placed while a recording runs
carries `"rec": {"id": <recording id>, "at": <seconds>}`, the time from the
start of the recording to the stroke's first point (the item's creation). It
is set when the stroke or item is added and never changes (a stroke sliced by
the eraser passes it to its pieces). A player can highlight or fade in what
was written up to the current position and seek to where a stroke was drawn;
with a transcript, a word's `start` finds the strokes drawn around it. A
`rec` naming a recording that is not present is ignored.

### 8.4 Limits

Writers must stay within, and readers may reject anything beyond:

| What | Limit |
| --- | --- |
| blob content (any kind, including future video) | 1 GiB (2^30 bytes) |
| transcript content | 64 MiB |
| text of one item | 65 536 UTF-8 bytes, 1 000 runs, 10 000 `breaks` |
| items per page | 10 000 |
| recordings per note | 1 000 |
| image to decode | 100 000 000 pixels (renderers draw a placeholder beyond) |

Frames, crops and coordinates are finite and within the renderer's extent
limit, as stroke coordinates are.

### 8.5 Rendering

#### 8.5.1 Mapping a source onto a frame

An image or PDF page is drawn by mapping its crop rectangle `[cx, cy, cw, ch]`
(source coordinates, y down) onto the frame `[fx, fy, fw, fh]`, then
rotating about the frame's centre `(mx, my)` by `rotation` θ:

```
p = (fx + (u − cx) · fw / cw,  fy + (v − cy) · fh / ch)
x = mx + (p.x − mx) · cos θ − (p.y − my) · sin θ
y = my + (p.x − mx) · sin θ + (p.y − my) · cos θ
```

The clip is the frame, rotated the same way.

*Image source coordinates* are oriented pixel coordinates `(u, v)`. For a
stored pixel position `(a, b)` in an image `w × h` pixels as stored:

| `orientation` | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `(u, v)` | `(a, b)` | `(w−a, b)` | `(w−a, h−b)` | `(a, h−b)` | `(b, a)` | `(h−b, a)` | `(h−b, w−a)` | `(b, w−a)` |

*PDF source coordinates* are effective-page coordinates `(u, v)`. For a
point `(a, b)` in PDF user space, with the visible box (CropBox ∩ MediaBox)
`[x0, y0, x1, y1]`, `bw = x1 − x0`, `bh = y1 − y0`, `s = a − x0`,
`t = y1 − b`:

| `/Rotate` | 0 | 90 | 180 | 270 |
| --- | --- | --- | --- | --- |
| `(u, v)` | `(s, t)` | `(bh − t, s)` | `(bw − s, bh − t)` | `(t, bw − s)` |
| `W' × H'` | `bw × bh` | `bh × bw` | `bw × bh` | `bh × bw` |

#### 8.5.2 Missing and unknown content

An item whose blob is missing, unreadable, invalid (§8.1.4) or of a type the
renderer cannot draw, and an item of an unknown or reserved kind (§7,
§8.2.7), is drawn as a placeholder: its frame (rotated) outlined 1 pt in
`#9AA0A6FF` with both diagonals. A background placeholder still fills its
frame (§8.2.3). The export goes on and reports each placeholder; it never
fails because of one.

#### 8.5.3 Text layout

Text is full Unicode: any script, mixed scripts, and right-to-left text.
Renderers draw it with fonts they have (system fonts in the app, bundled and
installed fonts in the CLI, `docs/attachments.md` §6), so glyph widths differ
between renderers. Layout stays consistent because the vertical metrics are
fixed by the format and the line breaks are the writer's:

- **Lines.** The text is split into paragraphs at `\n`. If `breaks` is
  present and valid (strictly increasing, every offset inside a paragraph,
  after its first character, and at a grapheme cluster boundary), each
  paragraph is cut into lines exactly at those offsets and nowhere else.
  Otherwise the renderer breaks each paragraph greedily into lines no wider
  than the frame width, at line-break opportunities of the Unicode line
  breaking algorithm (UAX #14); a renderer without a full UAX #14
  implementation must at least break after white space (Unicode
  `White_Space`, except no-break spaces), after `-` (U+002D), and between two
  characters of East Asian Width `W` or `F` (CJK), and breaks a word wider
  than the frame between grapheme clusters. Writers compute `breaks` the same
  way from their own fonts.
- **Widths.** The sum of the shaped glyph advances at each run's size.
  Renderers shape with whatever they have (CoreText; the CLI's own shaper,
  `docs/attachments.md` §10); a renderer that cannot shape a script draws it
  unshaped and reports it. White space at a line end does not count toward
  its width and is not drawn. A tab advances like four spaces. A line wider
  than the frame (another renderer's fonts are wider) overflows on its end
  side and is never re-broken or clipped.
- **Vertical metrics** (font independent). A line's size `S` is the largest
  run `size` on it (the box `size` for an empty line). Its height is `1.2 S`
  and its baseline is `0.95 S` below its top. The first line's top is the
  frame's top; each next line follows. So every renderer puts every line at
  the same height, whatever font it uses.
- **Direction and alignment.** Each line is reordered for display by UAX #9
  (rules L1–L2) with its paragraph's direction (`dir`); `start` aligns to the
  left of `[x, x + w]` for a left-to-right paragraph and to the right for a
  right-to-left one, `end` the opposite, `left`, `center` and `right` as
  named.
- **Decoration.** Underline: `S/18` thick, `0.12 ×` the run's size below the
  baseline; strikethrough at `0.3 ×` the run's size above it, same
  thickness.
- **Faces and fallback.** `b` and `i` select bold and italic faces of the
  family; a renderer without one emboldens (outline stroke of `size/30`) or
  slants (12°) the regular face. A character the chosen font lacks is drawn
  with another font that has it (preferring one for the run's `lang`). A
  renderer with no font for a character draws the missing-glyph box and
  reports which script was missing; an exporter must not produce an export
  that shows missing-glyph boxes without reporting it.
