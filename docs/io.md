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

## WebDAV sync (`Sources/InkWebDAV`)

The one target with network code. It talks to a plain WebDAV collection that
holds a copy of the vault folder (same layout, `vault.json` at the collection
root) using PROPFIND (Depth 1), GET, PUT, MKCOL and DELETE, so any server
works (Nextcloud, Apache `mod_dav`, nginx dav, rclone serve webdav,
wsgidav). Everything is behind `WebDAVTransport`; `URLSessionTransport` is
the real one (it never follows redirects, so credentials cannot be forwarded
and methods cannot be rewritten) and tests use an in-memory server.

**Security.** Basic auth, `https` only; `http` is accepted for `localhost`,
`127.0.0.1` and `[::1]`. Credentials in the URL are refused. Everything on the
server is already age-encrypted, except `vault.json` (public by design).
A remote `vault.json` with another `vaultId` aborts the run before any
change.

**What is synced.** `vault.json`, `rewrap-journal.json` and
`notes/<uuid>/<name>.age`. Remote entries that are not a lowercase-UUID note
directory or a canonical revision file name (format.md §5) are ignored and
listed, never downloaded, so a hostile name cannot escape the vault. `keys/`
and unknown files are not synced. A downloaded revision must start with the
age header or it is rejected.

**Write-once files.** For each note the run compares the local and remote file
sets with the set recorded at the last sync (`SyncState.files`):

| local | remote | in last sync | action |
| --- | --- | --- | --- |
| yes | no | no | upload (`If-None-Match: *`) |
| no | yes | no | download |
| yes | no | yes | the server dropped it: delete locally if compaction allows, else upload it again |
| no | yes | yes | we dropped it: delete remotely if compaction allows, else download it again |

An existing file is never overwritten on either side. Downloads go to a
`.inkvault-tmp-<uuid>` file in the target directory, are fsynced, and are
linked into place with `link(2)` (fails if the name exists), so a partial file
never appears under its final name and a file that showed up meanwhile wins.

**Compaction deletes.** Sync never decides on its own to delete. A removed file
is deleted on the other side only if `CompactionPlanner.deletable` says so,
with retention 0 (the side that removed it already applied the retention
window) over the revisions held locally: a delta needs a snapshot that covers it,
a snapshot needs one that subsumes it. For remote deletes the covering snapshot
must also be on the server. A snapshot removed locally can only be judged from
the `included` coverage recorded when it was last synced. Without an unlocked
vault nothing can be checked, so nothing is deleted. A removal that fails the
check is undone (the file is copied back).

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

**State.** `$XDG_STATE_HOME/inkvault/sync/<hash of URL and vault path>.json`:
file names, hashes, ETags and snapshot coverage, no secrets. Deleting it makes
the next run a first sync: nothing is deleted, nothing overwritten.

**Testing.** `scripts/test-webdav.sh` starts a local wsgidav
(`pip install wsgidav cheroot`) and runs the integration tests, which are
skipped unless `INKVAULT_WEBDAV_TEST_URL` is set.
