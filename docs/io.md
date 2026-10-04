# Vault I/O

How `Sources/InkVault` reads and writes a vault directory. Not normative:
`docs/format.md` is the format; this records the implementation choices on
top of it.

## Types

- `VaultManifest`: `vault.json` (§2), InkJSON conventions, pretty-printed.
- `BodyFraming`: `INKV` ‖ `0x01` ‖ tag ‖ `gzip(JSON)` (§4). gzip comes from
  CZlib with `windowBits = 15 + 16`; the gzip header has mtime 0 and OS 255,
  so output does not depend on the platform. Unframing without the vault
  secret returns the body marked `verified == false`.
- `Vault`: a `.inkvault` directory plus the identities it was opened with.
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
builds the ops for a new note (one page plus all metadata fields).

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
evicted vault looks empty. The app (`Apps/InkVault/InkVaultApp/CloudVault.swift`,
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
4. reads (`Vault.open`, `summaries`, `summary`, `identityFiles`) inside an
   `NSFileCoordinator` coordinated read of the vault folder, and writes each
   edit's delta (`Vault.apply`) inside a coordinated write of its
   `notes/<id>/` folder (vault creation: of the new vault folder), so iCloud
   sees and uploads the new revision files.

Every reload (pull to refresh) repeats steps 1–3, so revisions other devices
synced since appear as placeholders, are fetched, and then read. Vaults
outside iCloud skip all of this: no scan, no coordination.

## Atomic writes

Every file the library writes (revisions, `vault.json`, identity files, the
rewrap journal) goes through one helper:

1. write the bytes to `.inkvault-tmp-<uuid>` **in the destination directory**
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

Revisions are write-once: `write` refuses an existing name and a reused
`(device, seq)` before renaming. The existence check and the rename are not
one atomic step, but two writers can only race on one name if they share a
device id and sequence number, which the format already rules out.

`nextSeq` takes the largest `seq` seen in file names **and** in any readable
snapshot's `included`, so a device whose old revisions were compacted away
does not reissue a `seq` that a snapshot already claims to cover (which
would make readers drop the new delta).

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
   - **skip** it if its header has exactly one X25519 stanza per current recipient
     (and no other stanzas)
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
`addRecipient` / `removeRecipient` call) finishes step 3 and 4. Files that
are already current are skipped, so a run can be repeated any number of
times.

Why a stanza count and not "the header lists all recipients": X25519
stanzas carry only an ephemeral share, not the recipient, so a header cannot
be matched against public keys. Within one change the count differs (n−1 vs
n on add, n+1 vs n on remove), and on removal the tag under the new secret
also tells old from new. The journal blocks any other recipient change until
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
