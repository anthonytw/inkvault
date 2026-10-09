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
- **Not device facts.** Things that belong to one device (its keys, how it unlocks,
  its hardware, its caches, its window layout) never sync.

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
    "newNote.titleFormat":   { "value": "isoDateTime", "modified": 1760025600000, "device": "a1b2c3d4" },
    "photos.removeMetadata": { "value": true,          "modified": 1760025600000, "device": "a1b2c3d4" },
    "history.thinAfterDays": {                         "modified": 1760029200000, "device": "0f0e0d0c" }
  }
}
```

Each entry is one setting: its `value` (any JSON value; absent means "reset to the
default"), `modified` (Unix milliseconds) and `device` (the writer's 8-hex device id,
`format.md` §5). It is one file, not one per device, as the maintainer asked; section 3
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
  (written by a newer version) is merged by the same rule and written back unchanged.
  The app ignores it; the CLI lists it as unknown.
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

The device keeps, per vault, outside the vault (`UserDefaults` under the vault id,
like the backup record): whether sync is on, the keys it has overridden, its merged copy
of the shared settings, and the values it last applied (to tell its own edits from
values it received).

### 4.2 Turning it on

- **The vault has no shared settings yet** (no `settings.age`, or one with no entry
  for any setting this app knows): this device's current values become the shared set.
  Every synced setting is written, with this device's id.
- **The vault already has shared settings**: the app compares them with this device's
  values. When they agree, sync turns on silently. Otherwise it shows each setting that
  differs (the vault's value and this device's) and offers:
  - **Use the Vault's Settings** (the default): this device takes the shared values.
  - **Replace the Vault's Settings with This Device's**: every synced setting is written
    with this device's value (newer entries, so they win on every device).
  - Cancel leaves sync off and changes nothing.
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
Settings.

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

Every setting the app has today, and the rule. Shared keys are the names in the file;
the CLI uses the same names.

### 5.1 Synced

| Shared key | Setting (Settings ▸ section ▸ row) | Values | Default |
| --- | --- | --- | --- |
| `handwriting.recognize` | General ▸ Recognize Handwriting | `true`, `false` | `true` |
| `newNote.titleFormat` | New Notes ▸ Title | `dateAndTime`, `dateOnly`, `isoDateTime`, `weekday`, `custom`, `blank` | `dateAndTime` |
| `newNote.titlePattern` | New Notes ▸ Title ▸ Pattern (custom) | a pattern `notes new --title-format` accepts | `yyyy-MM-dd HH:mm` |
| `newNote.paper` | New Notes ▸ Paper | a paper object (`format.md` §5.4.2) | ruled |
| `newNote.layout` | New Notes ▸ Layout (also the new-note sheet) | `letter`, `a4`, `pagelessLetter`, `pagelessA4` | `letter` |
| `newNote.voiceNotebook` | New Notes ▸ Voice Notes | a notebook path (`format.md` §5.4) | `Inbox` |
| `recording.codec` | Recording ▸ Format | `aac`, `he-aac`, `alac` | `aac` |
| `recording.bitRate` | Recording ▸ Quality | 24000, 32000, 48000, 64000, 96000, 128000 (HE-AAC up to 64000) | 64000 |
| `recording.sampleRate` | Recording ▸ Sample Rate | 16000, 22050, 32000, 44100, 48000 | 48000 |
| `recording.channels` | Recording ▸ Channels | 1, 2 | 1 |
| `transcription.enabled` | Transcription ▸ Transcribe Recordings | `true`, `false` | `false` |
| `transcription.language` | Transcription ▸ Language | a locale identifier, or `null` (same as the device) | `null` |
| `math.recognize` | Math ▸ Convert to Math | `true`, `false` | `false` |
| `photos.removeMetadata` | Photos ▸ Remove Location and Camera Data | `true`, `false` | `true` |
| `history.thinAfterDays` | Version History ▸ Thin Autosaves Older Than | 7, 14, 30, 90, 365, 0 (never) | 30 |

These are choices about the notes themselves (how new notes start, how recordings and
photos are stored, how long autosaves are kept) or about features the user expects on
every device (recognition, transcription). Transcription and recognition still run on
each device: a device without the language model, or without the hardware, does what it
can, as today.

`newNote.layout` gets a row in Settings ▸ New Notes, so that it can be overridden like
the others.

### 5.2 Device-only by nature (never synced, no badge)

| Setting (where) | Why it stays on the device |
| --- | --- |
| Keep Screen On (General) | this device's screen and battery |
| Smooth Mouse Strokes (General, Mac) | the Mac's mouse or trackpad |
| Eraser type and object eraser size (editor) | Pencil and tool choices of this device (`EraserPreference`, `ObjectEraserSize`) |
| Tool palette shown, compact palette, page strip, column layout, sidebar selection | window layout and screen size of this device |
| Last equation style (math editor) | editor memory, not a setting |
| Math model (Math) | a model downloaded to this device |
| Transcription language model download | downloaded to this device |
| Search Recording Transcripts (search field) | a search option of this device's list |
| Device Keys ▸ rewrap modes | tied to keys; a weaker removal mode must be confirmed on the device that applies it |
| Save Key, New Key, remembered keys, Face ID or passkey unlock | this device's keys and how it unlocks (Keychain) |
| Backups (folder, reminder, last results) | a folder this device picked (`BackupStore`) |
| Quick capture (voice notes from the Lock Screen, widgets, Action button) | per-device capture profile and its Keychain item |
| Storage ▸ cache sizes | this device's disk |
| Last thinning run, attachment index, recent activity | this device's bookkeeping |
| App icon (none yet) | a per-device choice when it comes |
| Sync Settings with This Vault, and the overrides | the sync switch itself |

A future setting is device-only unless it is added to the shared catalogue
(`SharedSettingsCatalog` in `Sources/Sempere/SharedSettings.swift`), which needs a row in
the table above, a validation rule, and a default.

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
sempere settings list  [--all] [--json]      shared settings of the vault (and unknown keys)
sempere settings get   KEY [--json]
sempere settings set   KEY VALUE [--json]
sempere settings reset KEY [--json]
```

They read and write the vault's shared file only. **The CLI has no device overrides**:
it is not a device that applies settings; it edits the shared set that devices with
sync on follow (their overrides still win on those devices). `set` validates the value
against the catalogue (`true`/`false`/`on`/`off` for switches, numbers, names; JSON for
the paper) and refuses keys it does not know. `reset` writes a reset entry. Writes use
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
- Device logic (`SettingsSyncStateTests`): first enable on an empty vault (seed) and on a
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
