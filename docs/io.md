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
  Opened without identities it is locked and only lists names. Note-store
  methods (`write`, `readRevision`, `reconstruct`, `snapshot`, `compact`,
  `history`, `nextSeq`, `verify`) and identity files (`keys/`, §3.2) are
  extensions on it.

## Atomic writes

Every file the library writes (revisions, `vault.json`, identity files, the
rewrap journal) goes through one helper:

1. write the bytes to `.inkvault-tmp-<uuid>` **in the destination directory**
   (same filesystem, so the rename cannot turn into a copy);
2. `fsync` it;
3. `rename(2)` it onto the final name.

A reader or a sync client sees either no file (or the previous version) or
the complete new one, never a partial file. Temp names start with a dot and
lack the `.age` suffix, so every listing ignores them (`verify` reports a
leftover as `unknownFile`; nothing deletes it automatically).

Revisions are write-once: `write` refuses an existing name and a reused
`(device, seq)` before renaming. The existence check and the rename are not
one atomic step, but two writers can only race on one name if they share a
device id and sequence number, which the format already rules out.

`nextSeq` takes the largest `seq` seen in file names **and** in any readable
snapshot's `included`, so a device whose old revisions were compacted away
does not reissue a `seq` that a snapshot already claims to cover (which
would make readers drop the new delta).

## Recipient changes and resumability (§3.3)

The only in-place rewrite. Order of operations:

1. Write `rewrap-journal.json` at the vault root. When the secret rotates
   (recipient removed) it holds the **outgoing** vault secret, age-encrypted
   to the new recipient set.
2. Write `vault.json` with the new recipients and `vaultSecret` (fresh on
   removal).
3. For every revision file: decrypt with our identities, then
   - **skip** it if its header has exactly one stanza per current recipient
     and its tag verifies under the current secret (already done);
   - otherwise re-encrypt the same plaintext to the new set (on removal,
     first re-tag the unchanged gzip bytes with the new secret, after
     verifying the old tag with the outgoing secret) and replace the file
     atomically.
4. Delete the journal.

If the process dies anywhere, the journal is still there. `Vault.open`
notices it (`pendingRewrap`), keeps the outgoing secret so files not yet
rewrapped still verify, and `resumeRewrap()` (or simply repeating the same
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
