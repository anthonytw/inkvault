# Settings sync through the vault

Status: design accepted by the maintainer (2026-10-09); a first-release feature.
Normative format text is in `format.md` §13. This file says why, what syncs, and how
the app and the CLI behave.

## 1. Goal

A user with an iPad and a Mac sets the paper, the title format of new notes, the
recording quality or the photo privacy option once, and every device that opens the
same vault follows. The settings travel exactly like the notes: inside the vault,
encrypted to the vault's keys, through whatever moves the vault (iCloud Drive, a
Files provider, WebDAV, a backup and restore).

Non-goals:

- **No Apple key-value storage.** `NSUbiquitousKeyValueStore` and iCloud key-value
  storage are not end-to-end encrypted. Nothing about settings leaves the device
  except inside the vault.
- **No silent divergence.** A synced setting edited on one device changes it on every
  device. A device deviates only when the user says so, per setting.
- **Settings, not state.** Every setting syncs, scoped by device type (section 5).
  Device *state* never goes in the file: keys, Keychain items, Face ID or passkey
  enrolment, quick-capture key material, caches, bookmarks, window layout.

## 2. Where the settings live

One file at the vault root, `settings.age` (`format.md` §13):

- age-encrypted to the vault's recipients, like every revision;
- inside, the revision body framing of `format.md` §4 (`SMPR`, version, HMAC tag under
  the vault secret, `gzip(JSON)`), with `settings` where a revision has its note id. The
  tag means only a holder of the vault secret can write a file the app accepts: anyone
  can age-encrypt to the public recipients, nobody else can tag;
- recoverable with stock tools, like a revision:
  `age -d -i key settings.age | tail -c +38 | gunzip | jq .`

```json
{
  "format": "sempere-settings/1",
  "settings": {
    "all/newNote.titleFormat":   { "value": "isoDateTime", "modified": 1760025600000, "device": "a1b2c3d4" },
    "all/photos.removeMetadata": { "value": true,          "modified": 1760025600000, "device": "a1b2c3d4" },
    "mac/mouseSmoothing":        { "value": "strong",      "modified": 1760027400000, "device": "0f0e0d0c" },
    "all/history.thinAfterDays": {                         "modified": 1760029200000, "device": "0f0e0d0c" }
  }
}
```

Each entry is one setting. Its key is `<scope>/<name>`: the scope is `all` (every
device) or a device type, `mac`, `ipad` or `iphone`. The entry holds the `value` (any
JSON value; absent means "reset to the default"), `modified` (Unix milliseconds) and
`device` (the writer's 8-hex device id, `format.md` §5). It is one file, not one per device, as the maintainer asked; section 3
explains why concurrent writers still converge.

Why not a revision log like notes? Settings are a few dozen small registers that are
overwritten, not a history worth keeping. A single file that each writer merges into is
smaller, needs no compaction, and the per-key merge below gives the same convergence
for registers that a log would.

## 3. Merge: per key, last writer wins

The merge is per key, never per file:

- For each key, the entry with the greater `(modified, device, value)` wins: `modified`
  compared as integers, then `device` as a string, then the canonical JSON encoding of
  `value` (sorted object keys, an absent value lowest). This is a total order on
  entries, so the merge of two files is the same whichever is read first (commutative),
  however reads are grouped (associative), and merging a file with itself changes
  nothing (idempotent). Every replica that has seen the same entries holds the same
  settings.
- **Keys nobody knows are kept.** An entry whose key this app version does not know
  (written by a newer version, or a scope this device does not read) is merged by the
  same rule and written back unchanged. The app ignores it; the CLI lists it as unknown.
- **Writing a value** (an edit, a reset, a seed) gives the entry `modified =
  max(now, m + 1)`, where `m` is the `modified` of the entry the writer currently holds
  for that key. An edit therefore always beats the value its writer saw, even when that
  device's clock is behind the clock of the device that wrote the old value. Two devices
  that edit the same key without seeing each other's edit: the later clock wins (ties: the
  greater device id), which is what "last writer wins" can mean without a coordinator.
- **Resets are entries too** (no `value`): a reset is a value like any other for the
  merge, so it is not undone by a device that still holds the old value.

**Concurrent writers and the file.** iCloud Drive, a Files provider or a WebDAV server
keeps one copy of a mutable file: when two devices write `settings.age` at about the
same time, one copy may replace the other. Each device keeps its own merged copy of the
shared settings (section 4), so nothing is lost: whenever a device reads the file, it
merges it with its copy, and if the result differs from the file (the file lacks an
entry the device holds, or holds an older one), it writes the merged result back. So a
change lost in a file-level race comes back the next time its device syncs, and the
merge makes every device agree once each has read the others' entries. WebDAV sync
merges the two copies itself when both sides changed (section 8).

## 4. On a device

### 4.1 Opt-in per device and per vault

Settings ▸ **Sync Settings with This Vault** (off by default). It is per device and per
vault: a device that opens two vaults syncs with the one(s) it was switched on for,
and applies a vault's settings while that vault is open.

A device reads and writes the keys of scope `all` and of its own type: a Mac (the Mac
Catalyst app, or the iPad app on a Mac) is `mac`, an iPad `ipad`, an iPhone `iphone`.
Two Macs share the `mac/…` settings (the user's two Macs, or a family member's Mac on
the same vault); an iPad ignores them and keeps them in the file untouched. Devices are
not told apart by name: every device of a type shares that type's settings. A device
that must differ uses an override (section 4.3).

The device keeps, per vault, outside the vault (`UserDefaults` under the vault id,
like the backup record): whether sync is on, the keys it has overridden, its merged copy
of the shared settings, and the values it last applied (to tell its own edits from
values it received).

### 4.2 Turning it on

- **The vault has no shared settings yet for this device** (no `settings.age`, or one
  with no entry for any key this device reads, `all/…` or its own type's): this device's
  current values become the shared set. Every setting it reads is written, with this
  device's id. (The first Mac on a vault an iPad already syncs with finds the `all/…`
  entries, so it takes the branch below for those; its `mac/…` settings are seeded from
  its own values.)
- **The vault already has shared settings for this device**: the app compares them with this device's
  values. When they agree, sync turns on silently. Otherwise it shows each setting that
  differs (the vault's value and this device's) and offers:
  - **Use the Vault's Settings** (the default): this device takes the shared values.
  - **Replace the Vault's Settings with This Device's**: every synced setting is written
    with this device's value (newer entries, so they win on every device).
  - Cancel leaves sync off and changes nothing.
- A setting the vault has no entry for (a type's first device, a setting added by a
  later version) is seeded from this device's value without asking.
- Turning sync off keeps this device's current values and stops reading and writing the
  file. Its overrides are forgotten, and turning it on again starts over with the step
  above.

### 4.3 Synced and overridden settings

Each syncable setting on a device with sync on is either **Synced** or **Overridden**
("This Device Only"):

- Editing a synced setting changes the shared value for every device. That is what
  sync means; there is no silent local divergence.
- To deviate, the user chooses **Only on This Device** for that row (its context menu,
  or the control at the end of the row). The setting keeps its current value and becomes
  overridden: later edits stay on this device, later shared values do not change it.
  Overridden rows show a small **This Device** badge, which is also a menu with
  **Use Synced Value**.
- An override stays until the user chooses **Use Synced Value**: the setting then takes
  the shared value (or, if the vault has none for it, this device's value becomes the
  shared one). Setting an overridden row back to the same value as the shared one does
  **not** relink it: the state is explicit, never inferred from equal values.

Settings edited outside the Settings screen (the paper picker's "use as default", the
layout choice of the new-note sheet) follow the same rule: a synced setting changes
the shared value, an overridden one stays on this device. Overrides are chosen in
Settings. An override lives only on its device (with the vault's sync state) and
needs no device name: it is never written to the file.

### 4.4 When the app reads and writes the file

- It reads `settings.age` when the vault is unlocked, when Settings opens, when the app
  returns to the foreground, and on the vault's listing passes when the file's size or
  date changed; in iCloud Drive it downloads the file first, like `vault.json`.
- It writes when a synced setting changed on this device (about a second after the last
  change, so dragging through a picker writes once), and when a read found the file
  behind this device's copy (section 3).
- A value the app cannot use (a key it knows with a value of the wrong type or out of
  range, from a damaged file or a newer version) is not applied: the setting keeps its
  current value on this device, and the entry is kept in the file untouched.
- Settings added by a later app version: the first device with that version and sync on
  writes its current value as the shared one when the vault has no entry for it.

### 4.5 Read-only, legacy and untrusted vaults

Writing `settings.age` is a vault write: it is refused where every write is
(`format.md` §7.3 read-only vaults, §3.3.2 legacy vaults, §2.1 a tampered recipients
list). The app then pauses settings sync and says why under the switch; edits made
meanwhile are written once the vault is writable again (they are detected against the
last applied values). Reading and applying need the vault unlocked.

## 5. Which settings sync

Every setting syncs (maintainer, 2026-10-09). What differs is its **scope**: `all`, or
per device type. A per-type setting exists once for each type it applies to
(`mac/keepScreenOn`, `ipad/keepScreenOn`, …); a type it does not apply to has no key.
The names are the ones in the file and in the CLI.

### 5.1 Scope `all`

| Name | Setting (Settings ▸ section ▸ row) | Values | Default |
| --- | --- | --- | --- |
| `handwriting.recognize` | General ▸ Recognize Handwriting | `true`, `false` | `true` |
| `newNote.titleFormat` | New Notes ▸ Title | `dateAndTime`, `dateOnly`, `isoDateTime`, `weekday`, `custom`, `blank` | `dateAndTime` |
| `newNote.titlePattern` | New Notes ▸ Title ▸ Pattern (custom) | a pattern `notes new --title-format` accepts | `yyyy-MM-dd HH:mm` |
| `newNote.paper` | New Notes ▸ Paper | a paper object (`format.md` §5.4.2) | ruled |
| `newNote.layout` | New Notes ▸ Layout (also the new-note sheet) | `letter`, `a4`, `pagelessLetter`, `pagelessA4` | `letter` |
| `newNote.voiceNotebook` | New Notes ▸ Voice Notes | a notebook path (`format.md` §5.4) | `Inbox` |
| `recording.codec` | Recording ▸ Format | `aac`, `he-aac`, `alac` | `aac` |
| `recording.bitRate` | Recording ▸ Quality | 24000, 32000, 48000, 64000, 96000, 128000 | 64000 |
| `recording.sampleRate` | Recording ▸ Sample Rate | 16000, 22050, 32000, 44100, 48000 | 48000 |
| `recording.channels` | Recording ▸ Channels | 1, 2 | 1 |
| `transcription.enabled` | Transcription ▸ Transcribe Recordings | `true`, `false` | `false` |
| `transcription.language` | Transcription ▸ Language | a locale identifier, or `null` (same as the device) | `null` |
| `math.recognize` | Convert Handwriting to Math | `true`, `false` | `false` |
| `photos.removeMetadata` | Photos ▸ Remove Location and Camera Data | `true`, `false` | `true` |
| `history.thinAfterDays` | Version History ▸ Thin Autosaves Older Than | 7, 14, 30, 90, 365, 0 (never) | 30 |
| `search.transcripts` | Search ▸ Search Recording Transcripts (the search field) | `true`, `false` | `false` |
| `rewrap.onAdd` | Device Keys ▸ When Adding a Device | `header`, `reencrypt` | `header` |
| `rewrap.onRemove` | Device Keys ▸ When Removing a Device or Upgrading | `header`, `reencrypt` | `reencrypt` |

These are choices about the notes themselves (how new notes start, how recordings and
photos are stored, how long autosaves are kept, how files are rewrapped) or about
features the user expects everywhere. Recognition and transcription still run on each
device: one without the language model does what it can, as today. The rewrap modes
are policies of the vault; choosing the weaker removal mode still asks for confirmation
on the device where it is chosen, and the other devices follow it.

### 5.2 Per device type

| Name | Setting | Types | Values | Default |
| --- | --- | --- | --- | --- |
| `keepScreenOn` | General ▸ Keep Screen On | `ipad`, `iphone`, `mac` | `true`, `false` | `false` |
| `mouseSmoothing` | General ▸ Smooth Mouse Strokes | `mac` | `off`, `light`, `strong` | `light` |
| `eraser.mode` | the eraser's mode (object or pixel), last chosen | `ipad`, `iphone`, `mac` | `object`, `pixel` | `object` |
| `eraser.objectRadius` | Object Eraser Size (editor) | `ipad`, `iphone`, `mac` | 4, 8, 16, 32 | 8 |
| `palette.compact` | Compact Palette (editor) | `ipad`, `iphone`, `mac` | `true`, `false` | `false` |
| `quickCapture.notebook` | Quick Voice Notes ▸ Notebook | `ipad`, `iphone` | a notebook path | `Inbox` |
| `quickCapture.transcribe` | Quick Voice Notes ▸ Transcribe Voice Notes | `ipad`, `iphone` | `true`, `false` | `true` |
| `backup.reminderDays` | Backups ▸ Remind Me | `ipad`, `iphone`, `mac` | 0 (off), 1, 3, 7, 14, 30 | 0 |

Pencil and pointer choices, the screen, the tool palette and quick capture depend on the
kind of device; backups are usually made from one kind of device (the Mac). The
quick-capture preferences apply when quick capture is on for the vault on that device;
switching it on or off is not a setting (it creates or deletes the device's capture key,
which is state). The backup reminder applies once the device has a backup folder.

The app icon and an unlock preference do not exist yet. When they come they are
per-type settings: the icon (`ipad`, `iphone`, `mac`), and how the device prefers to
unlock (`ipad`, `iphone`, `mac`). The remembered key itself stays device state.

### 5.3 Device state (never in the file)

These are not settings; they describe one device, or hold secrets:

| State | Why |
| --- | --- |
| Keys, remembered keys, Keychain items, Face ID / passkey enrolment | secrets and this device's hardware |
| Quick capture on or off, its capture profile and capture key | key material (`format.md` §11) |
| Backup folder (bookmark) and last backup results | a folder this device picked |
| Tool palette shown, page strip shown, column layout, sidebar selection, saved windows | what this device's windows show at the moment |
| Last equation style in the math editor, recent searches, Recently Recognized | editor and search memory |
| Downloaded math models and transcription language models | files on this device |
| Cache size limits (drawing, attachment, render caches), last thinning run, attachment index | this device's disk and bookkeeping |
| PencilKit's own saved tools (`PKPaletteNamedDefaults`) | PencilKit's state, partly reset by the app |
| Sync Settings with This Vault, and the overrides | the sync switch itself |

A new setting is added to the catalogue (`SharedSettingsCatalog` in
`Sources/Sempere/SharedSettings.swift`) with its scope, values and default, and a row in
the tables above.

Later: telling devices of the same type apart by name ("my Mac" and "the family Mac"),
so that a setting can be scoped to one named device. Until then the local override is
the way for one device to differ (ROADMAP).

## 6. The app

- Settings gains a first section, **Sync Settings with This Vault**: the switch, and
  under it what it does, the vault it syncs with, and whether sync is paused (locked,
  read-only, a tampered device list) or found a settings file it cannot read.
- Rows of synced settings get a context menu (Only on This Device / Use Synced Value)
  and, when overridden, the **This Device** badge (`.help` on the Mac).
- Spanish strings for every new string (`Localizable.xcstrings`).
- The logic is in `Sources/Sempere` (`SharedSettings`, `SharedSettingsCatalog`,
  `SettingsSyncState`: merge, first enable, overrides, reconcile), tested on Linux. The
  app only maps keys to its `UserDefaults` values (`SettingsSyncBridge`) and runs the
  passes (`AppModel+SettingsSync`).

## 7. The CLI

```
sempere settings list  [--type all|mac|ipad|iphone] [--json]   shared settings (and unknown keys)
sempere settings get   NAME [--type T] [--json]
sempere settings set   NAME VALUE [--type T] [--json]
sempere settings reset NAME [--type T] [--json]
```

`--type` picks the scope: `all` by default; `mac`, `ipad` or `iphone` for a per-type
setting (`sempere settings set mouseSmoothing strong --type mac`). A name also accepts
the full key (`mac/mouseSmoothing`). `list` without `--type` lists every scope.
They read and write the vault's shared file only. **The CLI has no device overrides**:
it is not a device that applies settings; it edits the shared set that devices with
sync on follow (their overrides still win on those devices). `set` validates the value
against the catalogue (`true`/`false`/`on`/`off` for switches, numbers, names; JSON for
the paper) and refuses names it does not know, and a type a setting does not have. `reset` writes a reset entry. Writes use
the machine's device id (`DeviceState`) and the merge rule above. Exit codes as for
every command (`docs/cli.md`): 5 legacy vault, 6 untrusted recipients, 7 read-only.

## 8. The rest of the vault

- **Recipient changes** (`format.md` §3.3.1): `settings.age` is rewritten with the
  revisions (new recipients; re-tagged under a rotated secret after verifying under the
  previous one). A file that cannot be read or verified is reported, left as it is, and
  does not keep the journal: the next settings write replaces it.
- **Backups**: `sempere backup`, `restore` and the app's Backups copy `settings.age` like
  `vault.json` (the latest copy; earlier ones in `versions/`).
- **WebDAV sync**: `settings.age` is synced as a mutable file. When both sides changed
  and the vault is unlocked, the sync merges them (section 3) and writes the result to
  both sides; locked, it falls back to the `vault.json` rule (keep both, report a
  conflict). Push-only mirrors upload the local copy.
- **iCloud Drive**: the app downloads `settings.age` before reading it.
- **Web viewer**: ignores the file.
- **Older apps and CLIs** ignore unknown files (`format.md` §1), so they keep working
  with a vault that has `settings.age`. They do not rewrap it in a recipient change: the
  file is then left encrypted to the previous keys and tagged under the previous secret,
  newer readers report it as unreadable, and the next write from a device with sync on
  replaces it from that device's copy. A device removed by such an older app can read
  that stale copy (settings only, no note content) until it is replaced.

## 9. Format and compatibility

No vault format bump and no `features` entry: a `features` entry would stop every older
writer (`format.md` §2), and nothing older readers do with notes changes. `settings.age`
is a compatible extension (`format.md` §7.5): an unknown file to older readers. The file
carries its own version, `sempere-settings/<major>`; a reader that finds a later major
neither applies nor writes it (and the app says the vault's settings need a newer
version), so a later version can change the file's meaning safely.

## 10. Tests

- Core (`Tests/SempereTests/SharedSettingsTests.swift`): merge is commutative,
  associative and idempotent (property test over random entries), the write rule beats
  a skewed clock, resets win and lose by the same order, unknown keys and unknown entry
  members survive a merge and a rewrite, limits and hostile files fail with typed errors
  (and a fuzz target), the tag binds the file (another secret, a renamed file),
  recipient changes rewrap the file (add, remove with rotation, a file that does not
  verify is skipped), read-only and legacy vaults refuse writes.
- Device logic (`SettingsSyncStateTests`): device types read only `all/…` and their own
  type's keys and keep the others; first enable on an empty vault (seed) and on a
  vault with settings (no differences, use the vault's, replace the vault's); override
  lifecycle (override keeps the value, ignores remote changes, local edits stay local,
  equal values do not relink, Use Synced Value relinks and applies); reconcile pushes
  local edits, applies remote ones, seeds new keys, writes back a file behind its copy,
  never applies an invalid value.
- CLI (`Tests/CLITests/CLISettingsTests.swift`): list/get/set/reset with `--json`,
  validation errors, unknown keys preserved, merge with a file written by another
  device.
- WebDAV: a both-sides change merges; locked falls back to a conflict copy.
- Backup: the file is backed up and restored.
- App (CI): the bridge round-trips every catalogue key through `UserDefaults`, and the
  model's passes (enable, edit, remote change, override) against a temporary vault.
