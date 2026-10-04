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

The file is optional. A vault may be used with an identity that is only
in a device Keychain or supplied externally.

### 3.3 Changing recipients

Adding a recipient: append it to `recipients`, re-encrypt `vaultSecret`
to the new set, then re-encrypt every file under `notes/` to the new set
(payload unchanged, new file key and header). Removing a recipient: the
same, with a freshly generated `vaultSecret`. These are the only in-place
rewrites in the format; do them from one device while others are idle.

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
  counter increments on ties and resets otherwise.
- `device`: 8 lowercase hex chars, random per app installation. Never a
  hardware identifier.
- `seq`: per (note, device) counter, decimal, starting at 1, gap-free.

Ordering key for anything that needs a total order: `(hlc, device, seq)`.

### 5.1 Common fields

```json
{
  "type": "delta",
  "noteId": "…",
  "device": "a1b2c3d4",
  "seq": 12,
  "hlc": "00017596320000000003",
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
| `addPage` | `page: {id, order}` | add an empty page |
| `removePage` | `pageId` | remove page and its strokes; wins over adds |
| `setPageOrder` | `pageId`, `order` | LWW on the page's order key |
| `setMeta` | `field`, `value` | LWW per field (§5.4) |
| `deleteNote` | | LWW with `restoreNote` on `deleted` |
| `restoreNote` | | |

The LWW timestamp of an op is the revision's `(hlc, device)`.

### 5.3 Snapshot

Adds:

```json
"included": { "a1b2c3d4": { "upTo": 12, "extra": [15, 16] },
              "99ee00ff": { "upTo": 3,  "extra": [] } },
"state": State
```

`included` names every revision the snapshot already reflects: for each
device, all `seq ≤ upTo` plus the listed `extra` (seen out of order).
Readers reconstruct a note as: take the snapshot with the greatest
`(hlc, device, seq)` if any; apply every delta not covered by its
`included`. Because strokes merge as sets and metadata by LWW using the
op's own timestamp, the application order of deltas does not change the
result.

A device may write a snapshot at any time. Deltas covered by the newest
snapshot and older than the retention window (default 30 days by `wall`)
may be deleted; older snapshots may be deleted when a newer snapshot covers
everything they covered and they are older than the window.

### 5.4 State and metadata

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

- `created` is set once by the first revision and never changes.
- `paper.kind` ∈ `blank`, `ruled`, `grid`, `dot`. Lengths are points (1/72 in).
- `pageSize.infinite: true` means the page grows downward; `height` is then
  the current extent.
- In a snapshot, `pages` are sorted by `(order, id)`.

### 5.5 Page

```json
{ "id": "…", "order": "a0", "strokes": [ Stroke, ... ] }
```

`order` is any string; pages sort lexicographically by `(order, id)`. The
library provides a helper to generate a key between two neighbours.

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
- `points` are the control points of a uniform cubic B-spline, exactly as
  PencilKit's `PKStrokePath` exposes them: location `x,y` in points with
  origin top-left and y down; `t` time offset in seconds; `w,h` size in
  points; `o` opacity 0...1; `f` force; `az` azimuth and `al` altitude in
  radians. Writers round to at most 3 decimals.
- `transform` is an optional affine matrix `[a b c d tx ty]`; identity when
  absent.
- `parent` optionally names the stroke this one was sliced from.

## 6. Identifiers and encodings

UUIDs are lowercase, hyphenated. Times are RFC 3339 UTC. JSON writers must
not emit NaN or infinities. Numbers in `points` are plain JSON numbers.

## 7. Versioning

`format` in `vault.json` and the body version byte identify the format.
A reader that sees a higher major version must refuse to write and may
offer read-only access if it can parse the files.
