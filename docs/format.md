# Sempere on-disk format, version 1

Normative. Changes to this file are format changes and need a version bump
or a documented compatible extension.

## 1. Vault layout

A vault is a directory whose name ends in `.sempere`.

```
Notes.sempere/
  vault.json                              plaintext manifest (§2)
  keys/
    <key-name>.key.age                    optional passphrase-wrapped identity (§3.2)
  notes/
    <noteId>/
      <hlc>-<device>-<seq>.delta.age      append-only revision (§5)
      <hlc>-<device>-<seq>.snapshot.age   append-only snapshot  (§5)
      att/
        <blobName>.<kind>.age             the note's attachment bytes: images, PDFs, audio, transcripts (§8.1)
  inbox/
    <captureId>.capture.age               a voice note sealed without the vault's key (§11), until adopted
    <captureId>.transcript.age            its transcript, sealed the same way (§11)
  sempere-summaries.sealed                optional published note summaries, a hint for listing (§12)
```

Everything under `notes/` (revisions and `att/` blobs alike) is written once
and never modified. The only exception is a recipient change (§3.3), which
rewrites files in place (and renames blobs, §8.1.5).

Unknown files and directories must be ignored, never deleted.

## 2. vault.json

```json
{
  "format": "sempere/1",
  "vaultId": "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c",
  "created": "2026-10-04T16:20:00Z",
  "recipients": [
    { "key": "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p",
      "label": "Anthony's iPad", "added": "2026-10-04T16:20:00Z" }
  ],
  "vaultSecret": "-----BEGIN AGE ENCRYPTED FILE-----\n...\n-----END AGE ENCRYPTED FILE-----\n",
  "features": ["recipients-tag"],
  "recipientsTag": "5b0e6f…(64 hex digits)…"
}
```

- `format`: the format identifier, `sempere/<major>` (§7.1); `sempere/1`
  for this version. A reader opens a vault of a later major read-only or not
  at all (§7.3).
- `recipients[].key`: an age MLKEM768-X25519 recipient (§3.1, Bech32, HRP
  `age1pq`). At least one. Writers MUST NOT create a vault with, or add, an
  X25519 recipient (HRP `age`). A vault that lists any X25519 recipient
  (alone or next to MLKEM768-X25519 ones) is a **legacy vault**: it may be
  opened only to migrate it (§3.3.2).
- `vaultSecret`: 32 random bytes, age-encrypted and armored, to exactly the
  listed recipients. It keys the inner authentication tag (§4) and the blob
  names (§8.1.2), and nothing else in the vault; outside it, a reader may
  derive a per-device summary cache key from it (§10). It is rotated
  whenever a recipient is removed.
- `features` (optional, *new: attachments*): array of strings naming format
  extensions the vault uses. A writer adds `"attachments"` before it writes
  the first blob or attachment op (§8). A writer that finds a feature it does
  not implement must not write to the vault (it may still read it: read-only access, §7.3).
  Absent means `[]`. `"recipients-tag"` (*new: authenticated recipients*)
  says the vault carries `recipientsTag` (§2.1). `"signed-secret-link"`
  (*new: signed secret links*) says `secretLink` is never in the legacy HMAC
  form (§2.1 "Upgrading to signed links").
- `recipientsTag`, `secretLink` (optional, *new: authenticated recipients*):
  §2.1.

### 2.1 Authenticated recipients

*New: authenticated recipients.* `vault.json` is plaintext, and everything a
writer encrypts goes to the keys in `recipients`. Without this section,
anyone who can write the vault folder (a sync server, a shared folder, a
stolen backup put back) could add their own recipient, and every writer would
encrypt new revisions, blobs and captures to it. Revisions and blobs are
authenticated by the vault secret (§4, §8.1.2), which such an attacker does
not know; `recipientsTag` extends that to the recipients list, and
`secretLink` to the secret itself.

**Keys.** With `vaultSecret` (§2) as HKDF-SHA256 input key material
(RFC 5869, empty salt), as for the other derived keys (§10, §11.1):

```
recipientsKey = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 recipients key", L = 32)
secretId      = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 secret id", L = 32)
linkEdSeed    = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 secret link ed25519 seed", L = 32)
linkMLSeed    = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 secret link ml-dsa-65 seed", L = 32)
```

and two **link signing key pairs**, deterministic functions of the secret
(*new: signed secret links*; security review 2026-10, R2):

| Key pair | Derivation | Public key | Signature |
| --- | --- | --- | --- |
| Ed25519 (RFC 8032, pure, no context) | private key = `linkEdSeed` (the RFC 8032 32-byte seed) | 32 bytes | 64 bytes |
| ML-DSA-65 (FIPS 204) | `ML-DSA.KeyGen_internal(ξ = linkMLSeed)` (FIPS 204 Algorithm 16) | 1952 bytes (`pk`) | 3309 bytes |

ML-DSA-65 signatures are made with `ML-DSA.Sign` (pure, hedged or
deterministic: both verify the same) with an **empty context string**, and
checked with `ML-DSA.Verify` with an empty context. The private keys and
seeds are never stored; whoever holds the secret derives them again.
`linkPublicKeys(secret)` names the pair of public keys. Test vectors (fixed
secrets → seeds → public keys → links that verify, made by two
implementations) are in `Tests/SempereTests/Fixtures/secret-link-vectors.json`.

**Tag.** `recipientsTag` is the lowercase hex (64 digits) of

```
HMAC-SHA256(key = recipientsKey,
            message = "sempere/1" ‖ 0x00 ‖ "recipients" ‖ 0x00 ‖ vaultId
                      ‖ 0x00 ‖ key₁ ‖ 0x00 ‖ key₂ … ‖ 0x00 ‖ keyₙ)
```

over `vaultId` and every `recipients[].key`, in list order, each exactly as
written in `vault.json` (UTF-8; neither contains `0x00`). These are the fields
that decide who can decrypt: adding, removing, replacing or reordering a key
changes the tag. `label` and `added` are informational and not covered.
The tag also covers `vaultSecret` implicitly: under another secret it does
not verify.

**Secret link.** Anyone can encrypt a secret of their own to public keys, so
a forged `vault.json` could carry a fresh secret, the attacker's recipient and
a tag that verifies under that secret. Whenever a writer rotates the secret
(§3.3) it therefore writes `secretLink`: two signatures, by the **outgoing**
secret's link signing keys, over the link message

```
linkMessage = "sempere/1" ‖ 0x00 ‖ "secret link" ‖ 0x00 ‖ vaultId ‖ 0x00 ‖ secretId(new secret)
```

(`vaultId` lowercase, UTF-8; `secretId` the 32 raw bytes), as a JSON object
of lowercase hex strings:

```json
"secretLink": { "ed25519": "…(128 hex digits)…", "mldsa65": "…(6618 hex digits)…" }
```

A link is valid only when **both** signatures verify under the public keys
the reader holds for the outgoing secret; one valid signature alone (the
other missing, malformed, of another message or by another key) is
invalid. Two independent schemes are required so that the link stays
unforgeable while either one does (Ed25519 against classical attacks,
ML-DSA-65 against a quantum computer). Only a holder of the outgoing secret
can make the link, and a reader checks it with public keys alone. A value
of any other shape (a missing member, uppercase hex, a wrong length, not an
object) never verifies, and writers drop it. `secretLink` is kept, unchanged,
by changes that do not rotate the secret, and replaced by the next rotation.

A JSON string in `secretLink` is a **legacy link**, written before signed
links: the lowercase hex (64 digits) of
`HMAC-SHA256(key = legacyLinkKey(old secret), message = linkMessage)` with
`legacyLinkKey = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 secret link key", L = 32)`.
That key was also what a legacy trust record kept, so whoever could read such
a record could forge the link. A legacy link never confirms a rotation to a
trust record (below); it is checked only to accept a rewrap journal's
previous secret (§3.3.1), by a reader that holds both secrets (forging it
then needs `secretId(current)`, which only holders of the current secret know).

**Trust record.** A reader that writes keeps, per device and per vault,
outside the vault and never in it (like §10): the vault id,
`linkPublicKeys` of the last secret it verified, and the keys of the last
recipients list it verified. The reference implementation keeps it in
`$XDG_STATE_HOME/sempere/trust/<vaultId>.json` (CLI) and in the app's
Application Support folder, as

```json
{ "format": "sempere-trust/2", "vaultId": "…",
  "linkPublicKeys": { "ed25519": "…(64 hex digits)…", "mldsa65": "…(3904 hex digits)…" },
  "recipients": ["age1pq1…", …] }
```

It holds no secret and no key that can make a link or decrypt anything:
whoever reads it can check a `secretLink` but not forge one. It is still
kept private (it names the vault's devices; the CLI creates it mode 0600 in
a 0700 folder, the app excludes it from backups) and never copied between
devices. A **legacy record** (`"format": "sempere-trust/1"`, with a 64-digit
hex `linkKey` = `legacyLinkKey` of the secret instead of `linkPublicKeys`)
was written before signed links; it is read only until it is upgraded
(below) and never written.

**Writing.** Every write of `recipients` (creating a vault, adding, removing
or replacing a recipient, a migration, finishing an interrupted change, a
repair) writes `recipientsTag` under the secret written with it, in the same
atomic write of `vault.json` (§3.3.1 step 2), adds `"recipients-tag"` to
`features`, and, when the secret rotated, `secretLink`. Older writers do not
know the feature and stop writing (§2), so they never encrypt to a list they
cannot check nor drop the tag by rewriting `vault.json`.

**Checking.** A reader holding the secret classifies the list:

1. `recipientsTag` present: if it is not 64 lowercase hex digits or does not
   verify, the list is **tampered**.
2. `recipientsTag` absent: if `features` names `"recipients-tag"` or the
   device has a trust record for the vault, the tag was removed
   (a **downgrade**) and the list is tampered; otherwise the vault is
   **untagged** (written before this section).
3. The device has a trust record: this step is decided **before** steps 1
   and 2, whatever the tag says. If `linkPublicKeys` of the current secret
   equal the record's (both keys), the secret is the one the device verified;
   otherwise, if `secretLink` is a signed link whose two signatures verify
   under the record's public keys over `linkMessage` for the current secret,
   it is a rotation by a key holder. A legacy link never counts here. With a
   legacy record, the secret is the one the device verified when
   `legacyLinkKey` of the current secret equals the record's `linkKey`, and
   **nothing else is accepted** (no rotation, legacy or signed): whoever read
   that record could have forged a legacy link. Either way steps 1 and 2 then apply, and a list whose tag
   verifies is **verified**. If neither holds, the change is **unconfirmed**
   and the list is tampered, whatever keys it holds and whether its tag is
   present, absent or wrong (a tag is never judged, and no shorter list is
   searched, under a secret the device cannot link to its record): the new secret may be an attacker's,
   and a device that accepted it would also accept any later `secretLink`
   made under it, including one that adds the attacker's key. A device that
   missed two or more rotations therefore sees a tampered list, even when
   they only removed keys; it can confirm the list explicitly (below). A
   device never updates its trust record to an unconfirmed secret.
4. The tag verifies and the device has no trust record: verified (first use
   on this device).

A writer that finds the list verified saves it as its trust record before it
writes (a reader that only reads keeps none). A tampered list is **refused for
writing**: a writer encrypts nothing to it, neither revisions, blobs, inbox
files (§11), `vaultSecret` nor rewraps (§3.3.1, which it must not resume), and
reports the keys that are not in the last verified list (the **unexpected**
keys). Reading notes still works: revisions and blobs carry their own tags.
The last verified list is, when the current secret verifies a tag over the
current list with up to three entries deleted (order kept), that shorter
list: an attacker who only inserted keys is undone exactly, including keys
another device added since this one last checked. Otherwise it is the trust
record's list, if the device has one. The search runs only under a secret
that step 3 accepted (or with no record): under an attacker's secret it
would return a list holding the attacker's own key.

An untagged vault is upgraded by the first writer that holds the secret:
it writes the tag over the current list and the feature, and reports the
list it now trusts. This trusts whatever the list is at that moment
(trust on first use); a device that has a trust record never upgrades, it
reports a downgrade.

**Upgrading to signed links.** Vaults and records written before signed
links are migrated in place, once, by a device holding the secret whose list
checks (verified, or untagged and then tagged first):

1. **Record.** At the device's first write (any write: a writer saves its
   record before writing), its trust record is saved as `sempere-trust/2` for
   the current secret, replacing a legacy one. A legacy record therefore
   lives only until then, and only ever confirms the secret it was made for:
   a device that missed a rotation while its record was legacy sees the change
   as unconfirmed and confirms the list explicitly (below). There is no path
   back: no writer creates a legacy record, and a signed record never accepts
   a legacy link.
2. **Vault**, explicitly (`sempere vault link upgrade`; the app after
   unlocking) and as part of every write of `recipients` or of a tag, in the
   same atomic write of `vault.json`: a legacy link is **re-signed** when the
   outgoing secret is still known (an unfinished rewrap's journal, whose
   secret the legacy link connects to the current one) as a signed link from
   that secret, and otherwise **retired** (removed: it cannot be signed
   without the outgoing secret, and no record accepts it); a malformed link
   is removed; `"signed-secret-link"` is added to `features`, so older
   writers, which would rotate with a legacy link that signed records refuse,
   stop writing (§2).

`features` is not authenticated (security review 2026-10, N3): an attacker
can take the feature out or put a legacy link back, which changes nothing for
a device with a signed record; it only lets older writers write again.

**Repair.** A key holder repairs a list whose tag does not verify, or was
removed, by writing the last verified list (keeping the labels the current
entries have; a key the attacker deleted comes back with an empty label) as a
recipient removal (§3.3): the secret rotates and every file is rewrapped, so
no file stays encrypted to an unexpected key. An unconfirmed secret change
cannot be repaired this way: the files are tagged under a secret the device
no longer holds, so the user restores `vault.json` from a backup or another
device, or, when the device only missed a legitimate change, confirms the
current list explicitly after checking it (the tag must be present and verify
under the current secret; the trust record is updated, nothing in the vault
changes).
An untagged copy older than the tag (a restored backup) may be confirmed the
same way; it is then tagged again. A list whose tag does not verify is never
confirmed, and nothing here is ever done implicitly.

**Limits.** The check is only as fresh as the trust record. Signed links
protect against whoever reads a device's trust record (or a backup of it),
which holds public keys only; they do not protect against whoever held the
outgoing secret itself. A device that
opens a vault for the first time trusts the list it finds; a removed device,
which knew the outgoing secret, can still forge a `secretLink` for devices
that have not seen its removal; and an attacker who removes keys from the
list (without adding any) can stop those devices' keys from receiving new
files, which is reported as tampering but cannot be prevented. A device with no
trust record cannot tell a replaced secret from the real one (step 4); an
attacker who replaced it knows it and can plant revisions tagged under it,
and the vault's earlier revisions then fail their tags under it, which
readers report (§4).

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

Before any change a writer checks the current list (§2.1) and refuses
a tampered one (a repair, §2.1, starts from the last verified list instead).
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
   { "format": "sempere/1",
     "previousVaultSecret": "-----BEGIN AGE ENCRYPTED FILE-----\n...\n",
     "rekeyBlobs": true }
   ```

   - `format`: `sempere/1`.
   - `previousVaultSecret`: present only when the secret is rotated
     (removal): the outgoing 32-byte vault secret, age-encrypted and
     armored to the **new** recipient set. Absent when adding.
   - `rekeyBlobs` (*new: attachments*, optional): how blobs are rewrapped
     (§8.1.5): `true` re-encrypts each under a new file key, `false` rewrites
     only its header. Absent means the default policy of §8.1.5. A device
     finishing an interrupted change uses the recorded value.
2. Write `vault.json` with the new `recipients` and `vaultSecret`, and with
   `recipientsTag` (and, when the secret rotates, `secretLink`) for them
   (§2.1), in one atomic write.
3. For every file under `notes/` (revisions and `att/` blobs), skip it if it is already
   complete (below); otherwise rewrite it as described above, verifying its
   tag under the current secret or, failing that, under
   `previousVaultSecret`, and replace it atomically (temporary file in the
   same directory, then rename; blobs: §8.1.5). Files waiting in `inbox/`
   (§11) are rewritten the same way, re-tagged under the current secret's
   capture key (§11.1); one that cannot be decrypted or verified is left as
   it is, reported, and does not keep the journal.
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
unfinished: a writer whose list checks (§2.1) finishes steps 3 and 4 before
any other recipient change, and may verify tags under `previousVaultSecret` meanwhile. Readers
that do not implement this procedure treat the journal as an unknown file
(§1).

The journal is plaintext that anyone who can write the folder can plant,
and anyone can encrypt a secret of their own to the public keys. A reader
therefore uses `previousVaultSecret` only when it equals the current secret
(a change interrupted before step 2) or `vault.json`'s `secretLink` (§2.1)
verifies a rotation from it to the current secret. Otherwise the journal is
reported as unreadable: nothing verifies under its secret, and a writer does
not resume from it. A journal written before §2.1 (no `secretLink`) is
treated the same way; its files not yet rewrapped are reported as failing
their tags until they are restored from a backup.

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
| 0 | 4 | ASCII `SMPR` |
| 4 | 1 | body version, `0x01` |
| 5 | 32 | HMAC-SHA256 tag (below) |
| 37 | rest | `gzip(JSON)` (§5), gzip framing so `gunzip` reads it |

Tag = HMAC-SHA256(key = vaultSecret,
message = `"sempere/1" ‖ 0x00 ‖ noteId ‖ 0x00 ‖ filename ‖ 0x00 ‖ gzipBytes`),
where `filename` is the file's base name (e.g. `00017596...-a1b2c3d4-12.delta.age`)
and `noteId` is the note directory name. Binding the file name stops a
revision being replayed under another note or name. The label `sempere/1`
names this framing (body version `0x01`), not the vault's `format`: it stays
the same in a vault of a later major (§7.6).

A body version higher than the reader implements is newer content (§7.2):
the file is reported as newer, not as corrupt.

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
- `seq`: per (note, device) counter, decimal, starting at 1, gap-free,
  at most 2^53 − 1 (9007199254740991, the largest integer every JSON
  implementation holds exactly). A writer chooses `seq` greater than every
  `seq` for its device that appears in a file name of the note or is covered
  by any snapshot's `included` (§5.3), so a seq whose file was compacted away
  is never reused. Readers reject a larger `seq` in a file name, a revision
  or `included` (§9).

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
  "app": "sempere-ios/0.1"
}
```

`wall` is informational (history UI). `app` is informational.

*New: version history.* Three optional fields, which readers that do not
know them ignore (§7). A reader that knows them treats a value of the wrong
JSON type or form as absent; it never rejects the revision for it.

| field | on | value | meaning |
| --- | --- | --- | --- |
| `session` | delta | string, 1 to 64 characters from `[0-9a-z-]` | the editing session that wrote the delta (§5.8.2) |
| `checkpoint` | delta | object, optionally with `name` (a string) | the note as of this delta is a version the user saved (§5.8.1) |
| `asOf` | snapshot | `"<hlc>-<device>-<seq>"` | the snapshot holds the note as of that revision (§5.8.3) |

*New: versioning.* Two more optional fields mark a revision written by a
later version (§7.1): `format`, a format identifier (`"sempere/2"`), and
`features`, an array of extension names (§2). Writers of this version write
neither. Unlike the fields above, a malformed value rejects the revision
(§7.2), and a newer value makes the reader read the revision as §7.4 says and
keep the vault read-only (§7.3).

```json
{ "type": "delta", "noteId": "…", "device": "a1b2c3d4", "seq": 13,
  "hlc": "17596320000000009", "wall": "2026-10-04T16:25:00.000Z",
  "app": "sempere-ios/0.1", "session": "5f0c3e8a-2b7d-4c1e-9a3f-6d2b8e4f1a07",
  "checkpoint": { "name": "Before the exam" }, "ops": [] }
```

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
| `setPagePaper` | `pageId`, `paper` | LWW on the page's own paper (§5.4.2); `null` makes the page follow the note's paper again |
| `setMeta` | `field`, `value` | LWW per field (§5.4); writers never set `tags` (§5.4.1) |
| `addTag` | `tag` | add one instance of a tag (§5.4.1) |
| `removeTag` | `tag`, `observed` | remove the listed instances of a tag (§5.4.1) |
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
an `addStroke`, `setPageOrder`, `setPageRecognition`, `setPagePaper`, `addItem`
or `setItem` naming a page the writer has not seen, a `setItem` naming an item
it has not seen, or a `setRecording` naming a recording it has not seen, is
left out, so it is applied again once the page, item or recording arrives. An
id the writer knows only from a tombstone counts as seen (the op is a no-op).
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
(§8.1.6). *New: version history.* Compaction never deletes a checkpoint
(§5.8.1), and keeps each checkpoint that was a complete restore point (§5.7)
complete: it adds the positioned snapshots and keeps the witnesses that
§5.8.4 rules 2 and 3 require, with the checkpoints as the targets. Thinning
(§5.8.4) is compaction with a different choice of what to delete. A
compactor also keeps the first revision by `(hlc, device, seq)` while any
other revision has an earlier `wall`: `created` comes from the first
revision's `wall` (§5.4), so deleting it would let a later-ordered revision
whose device clock was behind move `created`, in the current state and in
every version.

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
    "pageSize": { "width": 612, "height": 792, "infinite": false },
    "lang": "en-US",
    "markersBehindText": true,
    "recognized": { "at": "2026-10-08T14:05:00Z", "pages": 5, "read": 2 }
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
- `paper` is the note's paper; see §5.4.2 for its kinds and parameters. Lengths are points (1/72 in).
- `pageSize.infinite: true` means the page grows downward; `height` is then
  the current extent.
- `pageSize.breakHeight` (optional, points): for an infinite page, the height
  of each page a paginating exporter (PDF) splits it into. Absent, it
  is `width × 11 / 8.5` (letter aspect). Ignored for finite pages.
  §5.4.3 calls this the note's *sheet height* and says how exporters
  paginate.
- In a snapshot, `pages` are sorted by `(order, id)`.
- `lang` (optional): the language the note is handwritten in, a BCP 47 tag
  (`en-US`, `es-ES`, `es`). Writers store 1 to 8 subtags of 1 to 8 ASCII
  letters or digits joined by `-`, the first subtag letters only, at most 64
  characters (Notability's `en_US` is stored `en-US`). Recognisers (§5.5) read
  the note's handwriting in this language; absent means the recogniser's
  default (the device language, or English). `setMeta` with `null` clears it.
  A `setMeta` value that is not such a tag is invalid (the revision is
  rejected); a snapshot `lang` that is not one reads as absent.
- `markersBehindText` (optional, boolean, absent means `false`): marker
  strokes (`ink.tool` `marker`) are drawn below the page's content items
  instead of above them (§8.2.3), as a highlighter behind typed text.
  Notability notes carry it (`NBNoteTakingSessionIsHighlighterBehindTextKey`).
  Writers omit it when false; a snapshot value that is not a boolean reads as
  `false`.

- `recognized` (optional, *new: shared Recently Recognized*): the last
  deliberate handwriting reading of the note ("Recognize All Notes" in the
  app, `sempere recognize` in the CLI), an object
  `{"at": RFC 3339 time, "pages": n, "read": m}`: when it ran (§6), how many
  pages the note had and how many of them it wrote recognition for (§5.5),
  integers with `0 ≤ read ≤ pages ≤ 100000`. It is written in the same delta
  as that run's `setPageRecognition` ops, only when the run wrote at least
  one (a note found current is left as it is). Apps list the notes whose
  `at` is within the last 7 days, and not more than a day ahead of the
  device's clock ("Recently Recognized"), on every device,
  since the register syncs like the rest of the note; the recognition a
  page's own editor writes as the user draws does not set it. `setMeta` with
  `null` clears it (the note leaves the list). A `setMeta` value that does
  not decode or breaks the bounds is invalid (the revision is rejected); such
  a snapshot value reads as absent.

`lang` and `markersBehindText` were added after the first snapshots were
written (*new: Notability import*), and `recognized` later still. Readers
that predate them reject a revision with a `setMeta` naming them (§7.4;
pre-1.0) and ignore them in a snapshot. A snapshot that holds neither a value nor a clock for one of them
never had it set, and does not compete with a `setMeta` it does not cover
(as `recognitionClock`, §5.5); a snapshot writes their clocks only once they
have been set.

`State` may carry `"clocks"`, mapping each LWW register (`title`, `tags`
(legacy, §5.4.1), `notebook`, `favorite`, `paper`, `pageSize`, `deleted`,
`lang`, `markersBehindText`, `recognized`) to the stamp of the
op that last set it, encoded `"<hlc>-<device>"`, e.g.
`{"title": "17596320000000003-a1b2c3d4"}`. A delta the snapshot does not
cover wins a register only if its own `(hlc, device)` is greater than that
stamp; between snapshots, the greater recorded stamp wins. A register with
no clock is treated as stamped by the snapshot's own `(hlc, device)`, except
the three optional ones above.

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
  instance of its key. Readers normalise `tag` the same way (in deltas and
  in snapshots) and ignore an instance whose tag is then empty.
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
`removeTag` reject revisions holding them (§7.4): such a reader must be
updated, not silently miss tags.

#### 5.4.2 Paper

`meta.paper` (and a page's own `paper`, below) describes the page background
and ruling:

```json
{ "kind": "cornell", "spacing": 24, "background": "#FFF8E1FF", "lineColor": "#D0D8E8FF",
  "lineWidth": 0.5, "cueWidth": 150, "summaryHeight": 120 }
```

`kind`, `spacing`, `background` and `lineColor` are always written. Every
other field is written only when it differs from the default of its kind
(table) and a missing field means that default, so a paper written before
these fields existed (`blank`, `ruled`, `grid`, `dot` with the first four)
decodes and renders exactly as before.

| field | meaning | default | valid range |
| --- | --- | --- | --- |
| `kind` | pattern, below | | |
| `spacing` | pitch of lines, grid and dots; for `isoDot` / `isoGrid` the dot pitch along a row | 24 | 4 … 200 |
| `background` | page colour `#RRGGBB[AA]` (presets: white `#FFFFFFFF`, cream `#FFF8E1FF`, dark `#1C1C1EFF`) | white | |
| `lineColor` | colour of rules and dots | `#D0D8E8FF` | |
| `lineWidth` | width of rules | 0.5 | 0.1 … 4 |
| `dotRadius` | radius of dots (`dot`, `isoDot`) | 0.9 | 0.3 … 4 |
| `marginLeft` | distance of a vertical margin line from the left edge; 0 = none | 0 (`marginRuled`: 72) | 0 … 300 |
| `marginTop` | distance of a horizontal margin line from the top; 0 = none | 0 | 0 … 300 |
| `marginColor` | colour of the margin lines | `#F2A6A6FF` | |
| `cueWidth` | `cornell`: width of the cue column | 150 | 40 … 400 |
| `summaryHeight` | `cornell`: height of the summary band | 120 | 40 … 400 |
| `staffSpacing` | `staff`: distance between the five lines of one staff | 7 | 3 … 20 |
| `staffGap` | `staff`: gap between one staff's bottom line and the next staff's top line | 40 | 8 … 150 |

Kinds (geometry is in page coordinates, origin top-left, y down; ruling is
laid out from the page's top so it continues unchanged down an infinite
page):

- `blank`: background only.
- `ruled`: a horizontal line at `y = k × spacing`, k ≥ 1, across the page.
- `marginRuled`: `ruled` whose `marginLeft` defaults to 72.
- `grid`: the `ruled` lines plus vertical lines at `x = k × spacing`, k ≥ 1.
- `dot`: a dot at every `(k × spacing, j × spacing)`, k, j ≥ 1.
- `isoDot`: dots in a triangular lattice: rows at `y = j × spacing × √3/2`
  (j ≥ 1), the dots of a row at `x = k × spacing`, shifted by `spacing / 2` on
  odd rows.
- `isoGrid`: the triangular grid through those lattice points: the horizontal
  rows plus the lines `x = n × spacing ± y / √3`, clipped to the page.
- `cornell`: the page (or, on an infinite page, each `breakHeight`-high sheet
  from the top) has a cue column `cueWidth` wide at the left, a summary band
  `summaryHeight` high at the bottom, a vertical line between the cue column
  and the notes area down to the summary band, a horizontal line along the top
  of the summary band (both twice `lineWidth`), and `ruled` lines at
  `spacing` across the notes area only. Cue width is limited to 60 % of the
  page width and the summary band to half a sheet.
- `staff`: staves of five lines `staffSpacing` apart, the first staff's top
  line at `y = staffGap`, the next one `staffGap` below the bottom line of the
  previous; `spacing` is ignored.

`marginLeft` / `marginTop` apply to `ruled`, `marginRuled`, `grid` and `dot`
and are ignored by the other kinds.

Writers keep every parameter inside its valid range. Readers render whatever
they find: they treat a non-finite or out-of-range parameter other than
`spacing` as clamped to its range (non-finite: the default), and draw no
ruling when `spacing` is below 4 or would need an unreasonable number of
lines (the plain background, as before).

**Unknown kinds.** A reader that does not know a `kind` treats the paper as
`blank` (keeping `background`), so a note written by a newer app still opens
and renders its strokes. (Readers older than this section reject the paper
and so the whole revision, as §7.4 says of anything unknown; this section
predates 1.0.) Such a reader keeps the unknown `kind` name and the fields
it knows when it rewrites `paper` (a snapshot or a restore), so compaction
on an older device does not turn the paper into `blank`; fields it does not
know are not kept. Apps should not offer to edit paper they could not render.

**Page paper.** A page may carry its own `"paper"`, which replaces the
note's `meta.paper` for that page; absent, the page follows the note. It is
an LWW register per page, set by `setPagePaper` (`null` clears it so the page
follows the note again), stamped in snapshots by the page's `"paperClock"`,
which works exactly like `recognitionClock` (§5.5): a page with neither
`paper` nor `paperClock` has never had its paper set and does not compete
with a `setPagePaper` the snapshot does not cover. `addPage` ignores any
`paper` in its page object. "Apply to all pages" is a `setMeta` of `paper`
plus a `setPagePaper` with `null` for each page that has its own. A page
added later follows the note's paper.

#### 5.4.3 Paged and pageless notes

A note is **paged** when `pageSize.infinite` is false: every page is a sheet
`width × height`, and pages are read top to bottom in page order (§5.5). It
is **pageless** when `infinite` is true: normally one page that grows
downward. Nothing else marks the layout; it is the `pageSize` register
(LWW, §5.4), so it needs no new op or field.

The **sheet height** `H` of a note is `height` when paged and `breakHeight`
(default `width × 11 / 8.5`) when pageless. Readers use `H = 792` when the
value is not finite or not positive, and clamp it to 72 … 200 000.

**Switching layout** is one delta written from the writer's current state.
It never deletes ink: every stroke that moves is re-added under a new id
with `parent` naming the old one (§5.2), its `transform` translated
vertically (`ty` changed, nothing else), so on screen and in exports each
stroke keeps its position relative to the sheet it is on, and ink keeps
its reading order. A re-added stroke keeps everything else, `rec` included
(§8.3.3). Placed items (§8.2) move the same way: `removeItem` (or the page's
`removePage`) and `addItem` of a new id with `parent` naming the old one
(§8.2.2), `frame` moved vertically by the same amount, every other field
kept; an item's sheet is the one holding the vertical centre of its `frame`.

- **Paged → pageless (join).** Let the pages be `P0 … Pn-1` in page order,
  and `s(P)` the sheets a page's ink reaches: 1 + the largest sheet `k` (as
  for a split, below) of its strokes and items, at least 1; it is 1 unless a
  concurrent edit left ink below the page. Page `Pj` starts at
  `oj = (s(P0) + … + s(Pj-1)) × H` (`j × H` when every `s` is 1), so ink
  below one page never lands on the next. `P0` stays. Each stroke of `Pj`
  (j ≥ 1), in that page's stroke order, is re-added to `P0` with `ty + oj`;
  then each `Pj` is removed (`removePage`). If any `Pj` (j ≥ 1) has
  recognition, `P0` gets one `setPageRecognition` (§5.5) whose `text` is the
  pages' texts joined by `\n` and whose `words` are theirs with boxes moved
  by `oj`. Own paper of pages after `P0` is not carried over. Last, `setMeta`
  of `pageSize` with `infinite: true`, the same `width`, `height` the total
  `(s(P0) + … + s(Pn-1)) × H` rounded up to a whole point, and
  `breakHeight: H`, so the pageless page's sheets are where the pages were.
  A pageless note with more than one page (a concurrent split that the
  note's own later `pageSize` write overrode, below) is joined the same
  way, with its sheet height.
- **Pageless → paged (split).** For each page `P` in page order: a stroke
  is on sheet `k = ⌊c / H⌋` (0 for negative or non-finite `c`), where `c` is
  the midpoint of the smallest and largest `y` of its control points after
  its transform. `P` becomes `m` sheets, `m − 1` being the largest `k` of
  its strokes and items, raised for a note with exactly one page to the number of
  whole sheets in `pageSize.height` (`⌊(height + 1) / H⌋`), at least 1 and at
  most 10 000 (larger `k` count as the last sheet). Sheet 0 is `P` itself
  and keeps its strokes. Each sheet `k ≥ 1`, blank ones included so later
  ink keeps its place, is a new page (`addPage`) whose `order` sorts after
  `P` and its earlier sheets and before the next page; each of its strokes
  is removed from `P` and re-added to it with `ty − k × H`; it gets `P`'s own
  paper, if any (`setPagePaper`). A recognition with `words` is split: each
  word goes to the sheet holding the vertical centre of its box (beyond the
  last sheet: the last), box moved by `−k × H`; a sheet's `text` is its
  words in order, separated by `\n` where the original text has a line
  break between them (found by locating each word in order in the text;
  if one is missing, all are separated by spaces), else by a space. `P`
  gets a `setPageRecognition` with its share; sheets without words get
  none. A recognition without `words` stays on `P`. Last, `setMeta` of
  `pageSize` with `infinite: false`, the same `width` and `height: H`.

**Recognition that moves** (join, split, and the duplicate and undo-delete
below) keeps telling current from stale (§5.5): its `basis` becomes the digest
of the receiving page's live strokes when every source page's recognition was
current (or the page was blank without any); it is absent when a source had
none (an import, kept until edited); and when a source was stale, or had ink
and no recognition, it is the digest of a freshly generated id, which matches
no strokes, so the text is read again. Text without `words` that stays on a
page whose ink a split moved away is stale.

Translations are exact up to the 3-decimal rounding of `transform` (§5.6),
so a split of a join (or a join of a split) puts every stroke back where
it was, under new ids. Strokes with a non-identity transform keep it:
only `ty` changes.

A concurrent revision merges with a switch like any other: a stroke
another device adds to a page the join removes is removed with it (as for
any page removal, §5.2); a stroke added to a pageless page below its first
sheet after a split was written stays on that page, below its bottom edge,
until the note is joined again. Readers draw and export it anyway (finite
pages, below). A device still drawing on the pageless page may write
`pageSize` (to grow it) after a concurrent split; that write wins the
register, leaving a pageless note with several pages, which readers show in
page order and a join merges.

**Page edits in a paged note** use the ops of §5.2, one delta per user
action:

- *Add a page* (after the current one, or at the end): `addPage` with an
  `order` strictly between its neighbours' keys (§5.5).
- *Move a page*: one `setPageOrder` with a key strictly between its new
  neighbours. Pages with equal keys (two devices inserted at the same place)
  sort by id; when no key fits between the new neighbours, the writer also
  gives the following pages new keys, in order, until one does.
- *Delete a page*: `removePage`. It wins over every concurrent edit of the
  page, a concurrent `setPageOrder` included.
- *Undo a delete*: the page id cannot be added again (§5.2), so the page is
  re-created as for a restore (§5.7): `addPage` with a new id and `parent`
  naming the old one, its strokes and items re-added under new ids with
  `parent` (and their `rec`), its recognition and own paper.
- *Duplicate a page*: `addPage` right after it, copies of its strokes and
  items under new ids (no `parent`: they re-create nothing; `rec` kept), its
  recognition and own paper.

Concurrent moves of one page resolve by LWW on its `order`; moves of
different pages all apply, so the result can interleave both devices'
intentions but always holds every live page exactly once.

**Exporting.** A paginating exporter (PDF, PNG) writes one output page per
page of a paged note, `width × height`. Ink below a finite page (a stroke
whose centre `c`, as for a split, is at or below `height`: only a concurrent
edit, above, or another writer leaves one) adds output pages of the same
size after it (at least 72 pt tall, the clamped sheet height), cut like a
pageless page from `height` down and keeping only those that hold ink
centred below the page, so no ink is lost; strokes merely crossing the
bottom edge are clipped by it. A
pageless page is cut into output pages of `width × H`: from the top `t`
of the current output page, the cut is at `t + H`, unless that line
crosses ink; then it moves up to the top of the ink it crosses, if that is
at least `t + 3H / 4` and makes room for the cut (a gap no stroke spans),
otherwise it stays at `t + H` and strokes crossing it appear on both
pages, clipped. A stroke spans the extent of its drawn outline (its
control points under its transform, widened by half its nib); a placed item
(§8.2) spans its frame and, below a finite page, counts by its frame's
vertical centre. The next
output page starts at the cut, and the paper is drawn over each whole
output page from `t` down, so ruling stays aligned with the ink. Notes
on `cornell` paper, whose layout repeats every sheet, are always cut at
`k × H`. Exporters may offer fixed cuts (`k × H`) as an option. A
non-paginating exporter (SVG) writes each page as one image of its full
extent.

### 5.5 Page

```json
{ "id": "…", "order": "a0", "strokes": [ Stroke, ... ], "items": [ Item, ... ],
  "recognition": Recognition, "parent": "…", "paper": Paper, "paperClock": "…" }
```

`items` (*new: attachments*) are the page's placed items (§8.2): text boxes,
images and PDF page backgrounds, sorted by `(layer, z, id)` (§8.2.3);
omitted when empty. `addPage` ignores any `items` in its page
object (the page is added empty). `recognition` is optional (below).
`paper` and `paperClock` are optional (§5.4.2).
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
  "engine": "vision-26.7",
  "text": "Lecture 3\nlinear maps",
  "words": [ { "t": "Lecture", "box": [52.5, 40.0, 96.25, 30.5] }, ... ],
  "basis": "9f2c4e1d7a0b3c58e6d1f4a2b7c90e13"
}
```

- `engine`: free-form name and version of whatever produced the text, e.g.
  `vision-<OS version>` (Apple's Vision on device: the app on iPadOS, or
  `sempere recognize` on macOS),
  `pencilkit-<iPadOS version>` or `notability-<version>` for an import.
- `text`: the page's recognised text in reading order, lines separated by `\n`.
- `words[].t`: one word of `text`; `words[].box`: its bounding box
  `[x, y, w, h]` in page coordinates (points, origin top-left, y down).
  Writers round to at most 3 decimals. `words` may be empty. Readers that
  draw boxes skip one with a value that is not finite or exceeds 10⁹ in
  magnitude, or a negative `w` or `h` (§9).
- `basis` (optional): which strokes the text was read from, so a writer can
  tell current recognition from stale without reading the ink. The first 16
  bytes, as 32 lowercase hex digits, of the SHA-256 of the page's live stroke
  ids (§5.2): each id as lowercase text, sorted as strings (byte order),
  joined by `\n` with no trailing newline. Strokes are write-once, so equal
  ids mean equal ink. An empty page's basis is the digest of the empty
  string, `e3b0c44298fc1c149afbf4c8996fb924`. Readers ignore a value they do
  not understand and treat it as an opaque string they only compare for
  equality.

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
highlight hits on the page. A recogniser reads a note whose `meta.lang` is
set (§5.4) in that language (with its own fallback when it does not support
it), and otherwise in its default language.

**When recognition is stale.** A page's recognition is *current* when it has
a `basis` equal to the digest of the page's live stroke ids; one with a
different basis is stale (strokes were added or erased since) and a writer
that recognises text replaces it, with a `basis` of its own. Recognition
without a `basis` (an import, or a writer that does not record one) cannot be
checked: a writer keeps it until it itself changes the page's strokes, and
then replaces it. A page with strokes and no recognition has none yet; a page
with no strokes keeps recognition without a `basis` and clears (sets to
`null`) one whose `basis` names strokes that are gone. Recognition with
empty `text` is valid and current: it says the page was read and had
nothing legible.

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
  SempereRender draws it); `o` opacity 0...1; `f` force; `az` azimuth and `al`
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
shows its `wall`, `device`, `app` and kind, except a snapshot with a valid
`asOf` (§5.8.3), which is history bookkeeping, not a version. A checkpoint
(§5.8.1) is flagged as one, with its name. The note **as of** revision R is
the reconstruction (§5.3) of every revision whose *position* is at or before
R. A revision's position is its own `(hlc, device, seq)`, except for a
snapshot with a valid `asOf`, whose position is its `asOf` (§5.8.3). For a
delta this is not necessarily what R's writer saw (a concurrent revision with
a smaller `hlc` is included, one with a larger is not); it is the only
definition every reader can compute the same way.

Compaction (§5.3) deletes revisions; they are no longer restore points. A
surviving revision R can still be shown only if each deleted revision is
covered by the `included` of a snapshot positioned at or before R, or is
provably ordered after R (R itself, or a surviving revision ordered after
R, of the same device with a smaller `seq`, precedes it). Otherwise readers
report R as incomplete and do not show or restore it. Likewise for an
unreadable revision ordered at or before R, and for every R while any
snapshot is unreadable (it may be the only record of compacted revisions).
A reader that does not know `asOf` positions every snapshot at its own name;
it may then report as incomplete a point that §5.8.3 makes complete, never
the other way round.

Restoring a note to R never rewrites or deletes history. A writer appends
one delta whose ops turn the current state into the state as of R:

- pages, strokes, items and recordings present now but not as of R:
  `removePage` / `removeStroke` / `removeItem` / `removeRecording`;
- pages, strokes, items and recordings present as of R but removed since:
  re-added under new ids (`addPage`, `addStroke`, `addItem`, `addRecording`;
  a re-added page gets its strokes, items, recognition and own paper from R,
  a re-added item or recording its register values as of R), with `parent`
  set to the old id (§5.2);
- `setPageOrder`, `setPageRecognition`, `setPagePaper`, `setItem`,
  `setRecording`, `setMeta` for every page order, recognition, page paper,
  item or recording register and metadata register that differs (except
  `tags`, and `recognized`, which records a reading rather than content and
  is kept as it is), and `deleteNote` or `restoreNote` if `deleted` differs;
- `removeTag` for every tag key present now but not as of R, `addTag` for
  every key present as of R but not now, and both for a key whose spelling
  differs (§5.4.1).

A page, stroke, item or recording counts as present when its id is, or when
one with `parent` naming it is (for a stroke, also with the same `ink`,
`points` and `transform`; for an item or recording, also with the same
immutable fields other than `id` and `parent`, §8.2.2), so restoring the same
point twice writes nothing the second time. Strokes and items are matched
only on the page that corresponds to theirs (the same id, or the re-created
page), so an item moved to another page since R (`removeItem` plus `addItem`
with `parent`, §8.2.2) is put back on its page as of R and its copy on the
other page is removed. An unknown field (§7.5) that an item or recording has now
but did not have as of R is left as it is: no op makes a field absent again
(`null` is a value of it, §8.2.2). Restoring never needs a blob the vault has deleted: a blob
referenced by any surviving revision of its note is never collected (§8.1.6). The delta's `hlc` is issued after observing every revision of the
note, so its LWW ops win over what they set back. Re-added strokes are
drawn above the strokes that stayed (they sort by their new `origin`).
Concurrent revisions the restoring device has not seen merge with the
restore as with any delta: strokes added to a surviving page stay, and
anything on a page the restore removes is removed with it.

### 5.8 Checkpoints, editing sessions and thinning

*New: version history.* Three optional fields (§5.1) let a history view say
which versions the user saved, group the autosaves between them, and let
compaction drop most autosaves without losing a saved version. None of them
changes how a note's state is merged (§5.3): a reader that ignores them
reconstructs exactly the same note.

#### 5.8.1 Checkpoints

A **checkpoint** is a delta with a `checkpoint` object: the note as of that
delta (§5.7) is a version the user saved on purpose ("Save Version"). `name`
is the user's label for it; absent, empty or not a string means unnamed.
Writers trim it, store at most 200 characters, and write the checkpoint as a
delta of its own, normally with `"ops": []` after saving any pending edits,
so the version is the note exactly as the user saw it. A checkpoint may carry
ops; the version is then the note as of the delta, ops included. `checkpoint`
on a snapshot means nothing and is ignored.

**Imports are checkpoints.** A writer that imports a note from another
application (the reference importer: `sempere import notability`, including
`--overwrite`) writes the import's delta as a checkpoint: it is a deliberate
full write of the note, not an autosave. The reference importer names it
`Imported from Notability on <UTC minute>` plus ` (modified in Notability
<UTC minute>)` when the source records a modification date. Its `wall` is the
import time, except for a note's first import, whose `wall` is the source's
creation date because it sets `created` (§5.4); the import time is then only in
the name. Imports written before this rule carry no `checkpoint` and are
autosaves (§5.8.4 may thin an older one).

A checkpoint is never deleted by compaction or thinning (§5.3, §5.8.4).
Checkpoints are not merged: two devices saving versions at the same time
make two checkpoints, each a restore point.

#### 5.8.2 Editing sessions

`session` is an opaque id an app chooses each time it opens a note for
editing (writers use a fresh lowercase UUID) and writes on every delta it
saves while that note stays open. Closing the note and opening it again, even
a minute later, starts a new id. Readers compare ids only for equality.

A history view groups restore points (§5.7) into **editing sessions**. Walk
the restore points in order; a checkpoint stands alone, at the top level, and
ends the session before it. Every other point joins the current session
unless any of these holds, in which case it starts a new one:

- (a) its `session` differs from the previous point's (absent counts as one
  more value: two points without `session` do not differ by this rule);
- (b) its `wall` is 10 minutes or more after the previous point's (a `wall`
  earlier than the previous point's is no gap);
- (c) its `device` differs from the previous point's.

"Previous point" is the one just before it in the walk, which is always in
the current session. A session is labelled by its first and last `wall`, its
device and its number of points. The grouping is derived, never stored: any
reader computes the same sessions from the same revisions.

#### 5.8.3 Positioned snapshots (`asOf`)

A snapshot with `asOf` = A holds the note as of the revision whose
`(hlc, device, seq)` is A (§5.7): its `state` is that reconstruction and its
`included` covers only revisions ordered at or before A (plus the snapshot
itself, §5.3). Thinning writes them (§5.8.4) so that the revisions a kept
version depends on can be deleted. For history (§5.7) such a snapshot is
*positioned* at A instead of at its own name; it is not a restore point. For
the note's current state (§5.3) it is an ordinary snapshot: it merges like
any snapshot written by a device that had seen only the revisions up to A,
which every reader already handles. Its writer records `clocks` for every
register and `origin` for every page, stroke, item and recording, as for any
snapshot, so its own `(hlc, device)` never stamps a value (§5.4).

`asOf` is **valid** when it parses (`hlc` 17 digits, `device` 8 hex, `seq` a
canonical decimal in 1 … 2^53 − 1, §5), is ordered strictly before the
snapshot's own name, and the snapshot's `included` covers no surviving
revision ordered after A other than the snapshot itself and other snapshots
with a valid `asOf` at or before A (a snapshot built from those holds their
content, which history places at or before A anyway). Readers decide
validity in order of `(asOf, name)`, so a snapshot may rely only on ones
decided before it. A reader that finds
`asOf` invalid positions the snapshot at its own name and lists it as an
ordinary restore point. A need not name a surviving revision.

#### 5.8.4 Thinning

Thinning removes old autosaves and keeps the versions a user is likely to
want. With a cutoff of N days (writers default to 30; "never" is allowed and
deletes nothing) and the note's revisions ordered by `(hlc, device, seq)`:

- The **thinned range** is the longest prefix of the order in which every
  revision's `wall` is more than N days old. A revision with a later `wall`
  (a device with a wrong clock, say) ends the range early; thinning never
  looks past it.
- Kept in the range: every checkpoint; the last restore point of every
  editing session (§5.8.2, sessions computed over all the note's restore
  points, so a session that continues past the range keeps its last point
  outside it); the note's newest revision; every snapshot whose valid
  `asOf` names a revision that is kept; the *witnesses* below; and the
  first revision while another has an earlier `wall` (§5.3).
- Everything else in the range may be deleted, deltas and snapshots alike,
  subject to the rules below. Revisions after the range are never deleted.

A cutoff of zero ("thin everything except checkpoints") puts every revision
whose `wall` is not in the future in the range: what stays is every
checkpoint, each session's last point and the newest revision. Writers offer
it as its own, explicitly labelled action, never as the default, and say in
the preview which rule applies and what it keeps.

Whether a note has anything to delete is decided from its revisions' names,
`wall`, `checkpoint`, `session`, `asOf` and snapshot `included` only, never
their ops or states; a thinner may keep that metadata per revision file
(§10) and read in full only notes that have a candidate.

A thinner must not delete anything until it has written the snapshots its
deletions rely on, and must keep these rules, which make every subset of its
deletions safe as well (a crash half-way leaves a correct vault):

1. **State.** A delta is deleted only if a snapshot that is not deleted
   covers it; a snapshot X only if a snapshot that is not deleted has an
   `included` that is a superset of X's and is either a strict superset or
   has a greater name (the order of §5.3, so two thinners or compactors
   running at once never delete each other's last cover).
2. **Kept versions.** Call *targets* the kept checkpoints and session ends,
   the newest revision, and every revision after the range, each one that
   was complete (§5.7) before thinning. Each target stays complete with the
   same note as of it. For each target T that a deletion would make
   incomplete, the thinner writes a snapshot with `asOf` = T, built from
   every revision positioned at or before T (before deleting anything). Its
   `included` then also covers the positioned snapshots among those, which
   §5.8.3 allows.
3. **Witnesses.** For a target T and a device X other than T's that has a
   revision ordered after T in the range that is deleted, the first revision
   of X ordered after T is kept. §5.7 can only tell that a deleted revision
   of X is ordered after T from a surviving revision of X at or after T with
   a smaller `seq`; the witness is that revision. A witness is not a target:
   it may itself become incomplete.

**Guarantees.** For any set of readable revisions (thinning refuses a note
with an unreadable revision):

- G1. The note's current state (§5.3) after thinning equals the state before.
- G2. No checkpoint is deleted; each target that was complete stays complete
  and the note as of it is unchanged.
- G3. No revision after the thinned range is deleted, and every blob stays
  (§8.1.6 collects blobs on its own terms).
- G4. Thinning twice with the same cutoff and no new revisions deletes and
  writes nothing the second time.
- G5. Every deleted revision is covered by a surviving snapshot, so the
  ordinary compaction rules (§5.3) hold, and every prefix of the deletion
  sequence keeps G1 and G2.

**Cost.** Each target that needs one gets a full snapshot of the note as of
it, so thinning can add up to (targets in the range) × (size of the note)
bytes while it deletes the autosaves between them; writers report both
before thinning (a dry run). In practice that is one snapshot per editing
session older than the cutoff that had more than one autosave. Readers that
predate this section see the positioned snapshots as ordinary ones (a kept
version may then show as incomplete, §5.7), and an older compactor may delete
checkpoints or positioned snapshots as it would any revision; a vault shared
with such a writer keeps its state but may lose saved versions.

## 6. Identifiers and encodings

UUIDs are lowercase, hyphenated. Times are RFC 3339 `date-time` in years
0001 to 9999: `YYYY-MM-DDTHH:MM:SS`, an optional fraction of 1 to 9 digits
(readers keep milliseconds), then `Z` (writers) or `±HH:MM` (readers
accept). Writers emit milliseconds, `2026-10-04T16:20:00.123Z`. JSON writers
must not emit NaN or infinities, and refuse a value they cannot represent
(a date outside those years) rather than write a file readers cannot decode.
Numbers in `points` are plain JSON numbers.

## 7. Versioning

### 7.1 Version markers

The format is identified by four markers:

| marker | where | this version |
| --- | --- | --- |
| `format` | `vault.json` (§2) | `"sempere/1"` |
| `features` | `vault.json` (§2) | `"attachments"` and `"recipients-tag"` are the extensions defined |
| body version byte | offset 4 of every revision body (§4) | `0x01` |
| `format`, `features` | a revision's JSON (§5.1), both optional | absent; absent `format` means `"sempere/1"`, absent `features` means `[]` |

A format identifier is `sempere/<major>`, where `<major>` is a decimal
integer from 1 to 999 999 999 without leading zeros. This document defines
major 1. A reader that implements major N reads every major up to N as
written; this section is about what it does with a higher one.

### 7.2 Newer content

A reader has seen **newer content** when any of these holds:

1. `vault.json`'s `format` names a higher major than it implements;
2. `vault.json`'s `features` lists an extension it does not implement;
3. a revision body's version byte is higher than it implements;
4. a revision's `format` names a higher major, or its `features` lists an
   extension it does not implement (a *newer revision*).

A `vault.json` whose `format` is not a format identifier, or names major 0,
is not a vault this reader can open: it refuses it (`unsupportedFormat`).
So does a reader that cannot decode a newer `vault.json` well enough to
decrypt `vaultSecret` (§2: `vaultId`, `recipients`, `vaultSecret`). A
revision whose `format` is present but not a format identifier (or names
major 0), or whose `features` is present but not an array of strings, is
invalid and rejected like any undecodable revision (§5).

Markers 1 and 2 are seen when the vault is opened; 3 and 4 only when the
revision is read, which may be later (a sync may deliver new revisions
before the new `vault.json`).

### 7.3 Read-only access

A reader that has seen newer content may offer **read-only access**
instead of refusing the vault, and must then never write to it. From the
moment it has seen newer content, for the rest of the time it has the vault
open (and, for markers 1 and 2, whenever it opens it), it:

- writes no revision: no delta (edits, imports, recognition, restores,
  checkpoints) and no snapshot;
- deletes no revision: no compaction and no thinning (§5.3, §5.8.4);
- writes, copies, renames, collects or repairs no blob (§8.1);
- starts, resumes or finishes no recipient change and rewraps nothing
  (§3.3), and writes no identity file (§3.2);
- does not change `vault.json` (not even `features`, §2), so it never tags
  an untagged vault (§2.1), and keeps no trust record for it;
- writes nothing to and deletes nothing from `inbox/` (§11): it adopts no
  capture and enables no capture profile.

It still may: read, verify and report on everything; export and render;
write per-device data outside the vault (caches, §10); and copy the vault's
files byte for byte without changing or deleting any by its own decision
(a backup, a sync that mirrors another replica's files).

The rule holds per vault, not per note: a newer revision in one note makes
the whole vault read-only. A reader must at least refuse every write to a
note whose revisions it has read and found newer, and every vault-wide
change (recipients, `vault.json`, `inbox/`) once it has seen newer content
anywhere. A reader that offers no read-only access refuses to open a vault
with marker 1, and treats a revision with marker 3 or 4 as unreadable
(reported, §4); it must still never write to a vault with marker 2 (§2).

### 7.4 Reading newer content

A read-only reader shows everything it understands and reports the rest. In
a **newer revision** (marker 4):

- An op whose `op` it does not know is skipped; the revision's other ops
  still apply, in order.
- An op it knows that does not decode or validate (a value of the wrong
  type, a `setMeta` or `setRecording` of a field it does not know, a
  `setItem` it would reject, §8.2.2) is skipped the same way.
- In a snapshot, an element of `pages`, of a page's `strokes` or `items`, or
  of `recordings` that does not decode is skipped; members of `state`,
  `meta` or a page that it does not know are ignored. If the envelope (§5.1),
  `included` or `state` itself does not decode, the whole revision is
  unreadable.
- Everything else follows the rules for any revision: unknown item kinds
  are drawn as placeholders (§7.5, §8.5.2), unknown fields are ignored or
  kept (§7.5), unknown ink tools render as `pen` (§5.6).

A file with a higher body version (marker 3) cannot be verified or decoded:
it is unreadable, reported as newer rather than corrupt, and the note is
reconstructed from its other revisions (§5.3).

In a revision that is **not** newer, an unknown op type or `setMeta` field
is invalid and the revision is rejected (fail closed), never applied in
part; this was the rule before read-only access existed and still holds,
so that a damaged or hostile file never passes for a newer one. A newer
revision gains nothing else: it is still decrypted, its tag (§4) verified
and its name checked (§5) like any other.

The state a read-only reader shows is approximate: a skipped op or element
may have removed, moved or replaced something it still shows (a snapshot
that covers a revision but holds none of an element it skipped hides that
element, §5.3). That is why such a state is only shown, never written.

The reader reports, per vault, why it is read-only (the vault's `format`,
its unknown `features`, and the notes holding newer content), and, per
note, what it could not show: the count of newer revisions, of unreadable
newer revisions, of skipped ops by `op` name (and `setMeta` fields by
name), and of skipped snapshot elements. Names are reported cut to 64
characters, at most 32 distinct names per note, the rest counted together
(§9).

### 7.5 Open extensions within a version

Until the first tagged release the format is pre-1.0: it may change without
a version bump or a migration path.

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

*New: authenticated recipients.* `recipientsTag` and `secretLink` (§2.1)
are a compatible extension: older readers ignore both fields and keep
reading, and the `"recipients-tag"` feature keeps older writers from writing
(§2). Nothing under `notes/` or `inbox/` changes, so the stock-CLI recovery
(§4, §8.1.7, §11.2) works as before.

A future change that older readers must not merge blindly (new merge
semantics, not just a new kind of placed content) still needs a new op type
in a newer revision, so that older readers skip it and stay read-only
(§7.4), or a `features` entry (§2), so that older writers stay read-only.

### 7.6 Writers of a later major

So that readers of this version can offer read-only access, a writer that
implements a later major N:

- sets `vault.json`'s `format` to `sempere/N` before it writes the first
  revision a major-1 reader would misread, and writes `"format":
  "sempere/N"` in every revision it writes from then on (a revision that
  uses an extension, `features`, lists it in the revision's `features`
  too);
- keeps `vaultId`, `recipients` and `vaultSecret` in `vault.json` (§2), and
  `recipientsTag` and `secretLink` as §2.1 defines them (a reader of this
  version that finds the tag removed reports tampering, §2.1), the key files
  (§3), the revision file names (§5) and the envelope fields of
  §5.1, with their meaning;
- keeps the body framing of §4, version byte `0x01` and tag label
  `sempere/1`, unless it must change them: the label names the framing, not
  the vault's format. A new body version makes its files unreadable to
  older readers (marker 3), and breaks the stock-CLI recovery path, which
  must then be documented anew.

The recovery path of §4 (`age -d … | tail -c +38 | gunzip | jq .`) and of
§8.1.7 therefore reads newer revisions too.

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
  (§8.2.5), `application/pdf` (§8.2.6), `video/mp4` and `video/quicktime`
  (§8.2.7), `audio/mp4` (§8.3.1), `application/vnd.sempere.transcript+json`
  (§8.3.2). Others are kept (§7.5).

Every blob reference in a revision is a JSON object with these three keys
(and possibly unknown ones, §7.5); no other object in a revision body has a
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
             message = "sempere/1" ‖ 0x00 ‖ "blob" ‖ 0x00 ‖ sha256)
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

`kind` is derived from the reference's `type`, compared on its type and
subtype only: ASCII case-insensitively, with any parameters (`; codecs=…`)
ignored:

| `type` | `kind` |
| --- | --- |
| `image/*` | `image` |
| `application/pdf` | `pdf` |
| `audio/*` | `audio` |
| `video/*` | `video` (§8.2.7) |
| `application/vnd.sempere.transcript+json` | `transcript` |
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
`hello, sempere!\n`, type `text/plain` (kind `bin`):

```
sha256    8ff2ca4079cee96a407a038a996ef5d0dd317f201fddc04174f0d89b763add65
blobName  13ddeae851cf51d7e9a970d82ca2c99f1dbaa3efaf792248da32b8374d6869af
path      notes/<noteId>/att/13ddeae8…69af.bin.age
header    494e4b4201 8ff2…dd65 0000000000000010   (45 bytes)
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

A change that both adds and removes follows the removal row, and so does an
addition that changes the set of stanza types among the recipients (for
example an MLKEM768-X25519 recipient added to a vault of X25519 ones, the
first step of a §3.3.2 migration by adding then removing). Implementations
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
that cannot be decrypted or verified (as a whole, §8.1.4, with the name
checked under the current secret) are never deleted by collection; they
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
padding after the content. `$((16#…))` is bash/zsh arithmetic, and BSD `head` (macOS) refuses
`-c 0` (an empty content has nothing to extract); where `xxd`
is missing, `od -An -v -tx1 | tr -d ' \n'` prints the same hex.

### 8.2 Placed items

A page's `items` (§5.5) are text boxes, images, PDF page backgrounds, video
clips, equations and recordings placed on the page, in page coordinates
(points, origin top-left, y down).

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

plus the fields of its kind (§8.2.4–§8.2.9).

- `id`: UUID.
- `kind`: `text`, `image`, `pdfPage`, `video` (§8.2.7), `math` (§8.2.8) or
  `audio` (§8.2.9); others per §7.5.
- `layer`: integer z-layer, 0 to 65 535 (§8.2.3). Defined: `0` background,
  `100` content. Absent means `100`. Writers write only defined values;
  readers order by any value in range and treat a value out of range or not
  an integer as `100`.
- `frame`: `[x, y, w, h]`, the item's box before rotation; `w` and `h` > 0.
- `rotation`: degrees, clockwise about the frame's centre; absent means 0.
- `z`: order key within the layer, compared like page `order` (§5.5).
- `parent`: optional, the item this one replaces (moved to another page or
  note, restored from history, or an image whose picture was replaced:
  `removeItem` of the old one and `addItem` of the new one in one delta,
  since `blob` is immutable, §8.2.2).
- `rec`: optional, as on strokes (§5.6, §8.3.3).
- `origin`: snapshots only, as on strokes (§5.5).
- `clocks`: snapshots only, maps each register (§8.2.2) to the
  `"<hlc>-<device>"` stamp of the op that last set it; a register without a
  clock is stamped by the snapshot's own `(hlc, device)`.

Numbers are rounded to at most 3 decimals by writers.

The fields of a defined kind (§8.2.4–§8.2.9) are required unless that section
says what their absence means (`rotation`, `crop`, `orientation`, `family`,
`lang`, `poster`, …). An item of a defined kind that lacks one, holds one of the wrong
type or out of its stated range (a frame, crop, `pixelSize` or `pageSize`
side not positive, `orientation` outside 1–8, a negative `pageIndex`, a text
`size` outside its range, a `duration` negative or not finite, a
`videoRotation` other than 0, 90, 180 or 270, a `recording` that is not a
UUID) is invalid like a bad common field: the revision is
rejected. A field of another kind on an item (an image with `pageIndex`) is
an unknown field there and kept (§7.5); so are all fields beyond the common ones
on an item of an unknown kind.

#### 8.2.2 Registers, ops and merge

Every field an item has is either a *register*, changed with `setItem` and
merged last-writer-wins per (item, field), or *immutable*, set by `addItem`
and never changed.

| Kind | Registers | Immutable |
| --- | --- | --- |
| every kind | `frame`, `rotation`, `z` | `id`, `kind`, `layer`, `parent`, `rec` |
| `text` | `text` | |
| `image` | `crop` | `blob`, `pixelSize`, `orientation` |
| `pdfPage` | `crop`, `pageText` | `blob`, `pageIndex`, `pageSize` |
| `video` | `poster` | `blob`, `pixelSize`, `duration`, `videoRotation`, `codec` |
| `math` | `math` | |
| `audio` | | `recording` |

- `addItem` sets every field; its register values carry the op's stamp.
- `setItem` with `field` naming an immutable field of any kind, or the
  snapshot-only `origin` or `clocks`, is invalid (the revision is rejected),
  as is a value of the wrong type or out of range for a register in the table.
  `value: null` (or no `value`) resets an optional register (`rotation`,
  `crop`, `poster`) to absent; `null` for `frame`, `z`, `text` or `math` is invalid. A field
  the reader does not know is a register (§7.5), and `null` is a value of it
  like any other.
- `setItem` on a removed item, or an item on a removed page, is a no-op.
  Writers name the item's own page in `setItem`; readers key the registers by
  item id and use `page` only to tell whether the op is an orphan (§5.3).
- A field named like an immutable field of some kind (`blob` on a text item,
  an unknown field there, §8.2.1) is not a register either: `setItem` can
  never name it, so it keeps the value its `addItem` gave it. Snapshot
  `clocks` list every register of the item, including `rotation`, `crop` and
  `poster` while absent (a reset is a value with a stamp, like `recognitionClock`,
  §5.5).
- Items merge as sets like strokes (§5.3), with permanent tombstones (§5.4).
  An item belongs to one page; moving it to another page is `removeItem`
  plus `addItem` of a new id with `parent` naming the old one (to another
  note: the same, with the blob copied first, §8.1.4).

Concurrent moves, resizes and text edits of one item therefore keep the last
writer's value per field; the other is still in history (§5.7).

#### 8.2.3 Layers and drawing order

A page is drawn, bottom to top:

1. the paper background colour (the page's own paper, else the note's, §5.4.2);
2. the paper ruling;
3. items by `(layer, z, id)`: lower layers first, then by `z`, then by `id`.
   An item whose `layer` is below 100 (a background layer) first fills its
   frame (rotated) with the paper background colour, so ruling never shows
   through it;
4. strokes, by `origin` (§5.5).

On a note with `markersBehindText` (§5.4), the marker strokes (`ink.tool`
`marker`) leave step 4 and are drawn, by `origin`, between the items of
background layers (below 100) and the first item of a layer of 100 or more;
on a page without such items, before the other strokes. Everything else is
unchanged: a highlighter then sits above a PDF page background but below
text boxes and images, and below pen ink.

Otherwise ink is drawn above every item, whatever its layer. Layers other than 0 and
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
  should store it; renderers use it (§8.5.3). `breaks` belong to the frame
  width they were computed for: a writer that changes a text box's width
  (a resize) writes the text again in the same delta, with new `breaks` (or
  none). An empty array is valid: the writer laid the text out and no
  paragraph wraps.
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

- `pageText` (optional register, *new: Notability import*): the page's text,
  for search: `{ "text": "…", "engine": "pdftotext-24.02", "truncated": true }`.
  `text` is the page's text in reading order, NFC, lines separated by `\n`
  (no other control characters but `\t`), at most 65 536 UTF-8 bytes;
  `engine` names what extracted it (`notability-<version>` for Notability's
  PDF index, `semperepdf-<n>`, `pdftotext-<version>`, `pdfkit-<OS version>`);
  `truncated` (absent means false) says the writer cut the text at the limit.
  It is derived from the blob and its page, describes the whole effective
  page whatever the `crop`, and a writer may set it with `setItem` at any time
  (`null` removes it), for example when a device that can extract text
  better reads an item another device added. Readers that index text for
  search take `text` (beside `recognition` and text boxes, §5.5, §8.2.4);
  a value that is not such an object (or whose `text` is longer than the
  limit) is ignored as if absent, never rejected. Older readers keep it as
  an unknown field and register (§7.5). It is never drawn.

The crop rectangle is drawn onto the frame (§8.5.1). The PDF's annotations
(`/Annots`) are not drawn; a writer that wants them flattens them into the
PDF before storing it. Within a note one PDF blob serves any number of
`pdfPage` items. How a writer lays pages out (one note page per PDF page, or
bands of an infinite page) is its choice (`docs/attachments.md`).

#### 8.2.7 Video

*New: video clips (`docs/attachments.md` §14, task G2).*

```json
{ "kind": "video", "layer": 100, "frame": [72, 144, 320, 180], "z": "a2",
  "blob": { "sha256": "…", "size": 48211330, "type": "video/mp4" },
  "pixelSize": [1920, 1080], "duration": 42.517, "videoRotation": 90,
  "codec": "hevc",
  "poster": { "sha256": "…", "size": 81211, "type": "image/jpeg" } }
```

- `blob` (immutable): the clip, kind `video` (§8.1.2), at most 1 GiB (§8.4).
  Writers store `video/mp4` (an ISO base media file, `.mp4`/`.m4v`) or
  `video/quicktime` (a QuickTime movie, `.mov`): a file that starts with an
  `ftyp` box (an older QuickTime movie may start with `moov`, `wide`, `free`,
  `skip` or `mdat` instead), holds one
  `moov` box with at least one video track (`hdlr` `vide`) whose first sample
  entry is H.264/AVC (`avc1`, `avc3`) or HEVC/H.265 (`hvc1`, `hev1`), and
  optionally sound tracks (AAC, `mp4a`, recommended) and others (timed
  metadata, timecode). Writers convert anything else first (another codec,
  WebM, AVI, fragmented MP4 without a `moov` sample table) or refuse it. They
  should place `moov` before `mdat` ("fast start") so a reader can show the
  clip's size before reading the samples; readers accept either order.
- Metadata: unless the user chose to keep it, writers remove the location
  and device metadata from the stored bytes: every `udta` and `meta` box
  directly inside `moov` or a `trak` (`©xyz`, `com.apple.quicktime.location.ISO6709`,
  make, model, software, creation date), every top-level `meta` box, and
  every XMP `uuid` box (usertype `BE7ACFCB-97A9-42E8-9C71-999491E3AFAC`,
  which may hold `exif:GPSLatitude` and the like) at the top level or
  directly inside `moov` or a `trak`, and a top-level `udta`, has its type changed to `free` and
  its contents set to zero bytes. Positions recorded per frame in the
  samples of a timed-metadata or text track (a drone's or action camera's
  telemetry) are not removed this way. Nothing else moves, so every sample offset
  (`stco`, `co64`) stays valid and the clip plays unchanged. Exporters do the
  same to bytes they pass through into an export unless asked to keep them
  (as for images, §8.2.5). Stripping fails closed: a file with more than one
  `moov`, or whose last top-level box other than `mdat` runs past the end, is
  refused rather than stored with metadata the walk did not see.
- `pixelSize` (immutable): `[w, h]`, the clip's display size in pixels: the
  video track's `tkhd` width and height, swapped when `videoRotation` is 90 or
  270. For layout and the poster's aspect; players use the decoded size.
- `videoRotation` (immutable, optional): `0`, `90`, `180` or `270`, the
  clockwise rotation the video track's `tkhd` matrix applies for display
  (an iPad held upright records 90); absent means 0. Informational: players
  apply the track matrix themselves, and `pixelSize` and the poster are
  already upright. It is independent of the item's `rotation` (§8.2.1).
- `duration` (immutable): seconds, 3 decimals, finite and not negative: the
  movie's `mvhd` duration (the video track's `mdhd` duration when `mvhd` has
  none).
- `codec` (immutable, optional, informational): `h264` or `hevc`, the video
  track's codec; other names may come from importers.
- `poster` (optional register): an image blob reference (§8.2.5 rules for
  `image/jpeg` and `image/png`, metadata stripped), the frame shown before
  the clip plays and the only part of the item that renderers draw. It is
  stored upright: renderers ignore any orientation in its data. Its aspect
  should match `pixelSize`; renderers scale the axes independently. Absent
  (or `null`) means no poster: a writer that cannot decode the clip (the CLI
  on Linux without `--poster`) leaves it absent, and a device that can (the
  app) may set it later with `setItem`, as for `pageText` (§8.2.6). A value
  that is not a blob reference is invalid (§8.2.2).

Drawing (renderers, exports and readers that do not play the clip, or before
it plays): the whole poster is mapped onto the frame (§8.5.1, with the crop
`[0, 0, w, h]` of the poster's decoded size, orientation 1), clipped to the
frame, then a *play mark* is drawn over it: with `d = min(48, 0.3 · min(fw, fh))`
and the frame's centre `(mx, my)`, a disc of diameter `d` centred there,
filled `#00000080`, and a triangle filled `#FFFFFFFF` with corners
`(mx − 0.18 d, my − 0.25 d)`, `(mx − 0.18 d, my + 0.25 d)` and
`(mx + 0.27 d, my)`; both are turned with the item's `rotation` about
`(mx, my)`. An item whose poster is absent, missing, invalid or not
decodable is drawn as a placeholder (§8.5.2) with the play mark over it, and
counted in the export report like any placeholder (an absent poster is
reported as "no poster", not as missing content). A video item counts toward
an infinite page's extent and is cut across export pages like an image.

Playing: a reader that plays video plays the verified clip (§8.1.4) from a
private temporary file or memory (`docs/attachments.md` §2 "Large files"),
applies the track matrix, and draws the frame's rectangle with the decoded
picture fitted inside it (aspect kept). A reader that cannot play the clip
(no decoder for its codec, a renderer, an exporter) shows the poster and play
mark as above and may offer the clip as a file. A `pdf` export with
attachments embeds the clip as an embedded file (`docs/attachments.md` §10).

#### 8.2.8 Math

*New: math items.* An equation, edited as LaTeX source and drawn typeset:

```json
{ "kind": "math", "layer": 100, "frame": [72, 300, 163.25, 41.5], "z": "a3",
  "math": {
    "latex": "\\int_0^1 x^2\\,dx = \\frac{1}{3}",
    "display": true, "size": 20, "color": "#1A1A1AFF",
    "render": { "sha256": "…", "size": 5120, "type": "application/pdf" },
    "renderSize": [163.25, 41.5], "engine": "swiftmath-1.7.3" } }
```

`math` is the item's only register of its own, and it is replaced whole
(like `text`, §8.2.4): the rendering belongs to the exact source, style,
size and colour it was typeset from, so concurrent edits never pair one
device's source with another's rendering. Its fields:

- `latex`: the source, in LaTeX math mode without delimiters (no `$`, `\[`
  or `\begin{equation}` around it): at most 8 192 UTF-8 bytes of Unicode
  scalar values, no C0 controls other than `\n` and `\t`. Writers store it
  as the user typed it (NFC) and do not write an empty source (they remove
  the item instead); an empty one is valid and draws nothing.
- `display`: `true` for display style (large operators, limits above and
  below, full-size fractions, as in `\[…\]`), `false` for text (inline)
  style (as in `$…$`). The item is placed freely either way.
- `size`: the font size of the typeset result in points (1 em), greater than
  0 and at most 1000. `color`: `#RRGGBBAA`, the colour of every mark.
- `render`: optional, a blob reference (§8.1.1) to the typeset result: a PDF
  (`application/pdf`, kind `pdf`; versions 1.0–2.0, no `/Encrypt`, as for
  `pdfPage`, §8.2.6) whose first page's effective page (§8.2.6) is the
  typeset box, in points at `size`, with the margin the writer chose. It
  draws only marks in `color` (alpha included) on a transparent page: no
  page fill, no other colour. Absent: no typesetter has rendered this value
  yet (a writer without one, such as the reference CLI, writes none).
- `renderSize`: `[w, h]`, the size in points of `render`'s effective page,
  both positive; present exactly when `render` is (else the item is
  invalid). Informational like `pageSize` (§8.2.6): renderers that parse the
  PDF use its own boxes; writers use it to keep the frame's scale.
- `engine`: optional, informational: the typesetter and its version that
  made `render` (e.g. `swiftmath-1.7.3`, `tectonic-0.15`).
- Unknown fields of `math` are kept (§7.5) and belong to the value: a writer
  that changes the source drops the ones it does not understand.

A writer that changes `latex`, `display`, `size` or `color` writes a new
`render` (or none) in the same value; a value whose `render` was typeset
from something else is a writer bug that readers cannot detect. When it
stores a new `render` it also sets `frame` in the same delta: the same
top-left corner, the render's page size times the scale the frame had to the
previous render (`frame.w / renderSize.w` of the old value; 1 when there
was none). Writers keep the frame's aspect
ratio equal to the render's; renderers scale the axes independently.

**Drawing.** A renderer draws the first of these it can:

1. `render`: page 1 of the PDF (`pageIndex` 0) mapped onto the frame and
   rotated exactly like a `pdfPage` item without `crop` (§8.5.1), clipped to
   the frame. A renderer that rasterizes the page onto an opaque white
   background (the CLI's Poppler, Core Graphics as the app uses it) recovers
   the coverage from the known `color`: a pixel `p` of channel `k`, where `k`
   maximises `255 − color_k`, has coverage `(255 − p_k) / (255 − color_k)`
   (clamped to 0…1), drawn in `color`; when every channel of `color` is
   above 250 the page is drawn as rasterized.
2. Its own typesetting of `latex` (the app, when there is no `render` yet),
   within the limits below.
3. The source as text: a text item (§8.2.4) with `font` `mono`, the math
   `size` and `color`, the frame, and one run holding `latex`, laid out by
   §8.5.3 without stored breaks. The export reports it like a placeholder.
4. The placeholder of §8.5.2.

**Limits of typesetting.** `latex` is untrusted input (§9). Before a
typesetter parses it, readers check it and treat a source that fails as one
they cannot typeset (step 3): more than 4 096 tokens (a token is a control
sequence, `\` plus letters or `\` plus one character, or any other
character that is not white space); a group closed by the wrong kind or
never closed (`{…}`, `\left…\right`, `\begin{…}…\end{…}`, and `[…]`
right after `\sqrt`, its degree, closed by the next `]` of the same level);
or a nesting deeper than 64, where each open group counts one level and so
does each control sequence, `^` or `_` in a run of them (the arguments a
typesetter would parse recursively; `\sqrt\sqrt\frac` is three levels, any
other token ends the run). A group opened after a run sits below it and was
an argument: the run goes on after it closes (`\frac{a}\frac{b}\frac{c}d`
nests each `\frac` in the one before). `\over`, `\atop`, `\choose`,
`\brack` and `\brace` add one level for the rest of their group, the
denominator (`a\over b\over c` is two). Writers never store a `render` for such a source.

**Text, search and export.** `latex` is part of the page's searchable text,
beside `recognition`, text boxes and `pageText` (§5.5); it is never copied
into `recognition`. Text exports (Markdown, HTML) write it as `$$latex$$`
for display style and `$latex$` for text style. A device that converts
handwriting into an equation writes one delta that removes the strokes and
adds the `math` item (`docs/attachments.md` §6, task G1).

Readers that predate this section keep a `math` item as an unknown kind
(§7.5): `math` is then an unknown field and register on it, `render` is found
by collection (§8.1.6), and they draw a placeholder.

#### 8.2.9 Audio

*New: recordings on the page (build 7 feedback).* A recording belongs to the
note (§8.3.1); an `audio` item shows one on a page, where it can be played
from, moved, resized and deleted like any item.

```json
{ "kind": "audio", "layer": 100, "frame": [72, 144, 300, 96], "z": "a3",
  "recording": "0d9e5c1a-…" }
```

- `recording` (immutable): the id of a recording of the same note (a UUID,
  written lowercase). The item shows the recording with that id; if it is not
  present, the present recording whose `parent` names it (one re-created by a
  restore, §5.7; the first by `(started, id)` if several), as for `rec`
  (§8.3.3); otherwise the recording is *missing*. Any number of items may
  show one recording, on any pages.
- The item has no registers of its own: its title, duration and transcript
  are the recording's (§8.3.1, §8.3.2), so renaming or transcribing the
  recording changes every item that shows it.

Writers: an app that stops a recording should place one `audio` item on the
page the user was looking at, in the same delta as the `addRecording`, so
the recording is never off the page. Removing an `audio` item (`removeItem`)
removes only the item: the recording stays in the note (a reader lists the
note's recordings, §5.4, and can place it again). Removing a recording
(`removeRecording`) should remove, in the same delta, the `audio` items of
its note that show it; an item left showing a missing recording (a
concurrent removal, an older writer) is drawn as below and may be removed by
any writer.

Drawing (renderers, exports, and readers before they play): with the frame
`[fx, fy, fw, fh]`, `m = min(fw, fh)`, the padding `p = min(8, 0.1 · m)` and
the icon size `d = min(24, m − 2p)`, everything below in frame coordinates
and then turned with the item's `rotation` about the frame's centre:

1. the *card*: the frame filled `#F1F3F4FF` and outlined 1 pt in
   `#DADCE0FF`;
2. the *icon*, when `d > 0`: a disc of diameter `d` filled `#1A73E8FF`
   centred at `(cx, cy) = (fx + p + d/2, fy + p + d/2)`, and over it, in
   `#FFFFFFFF`, a microphone: a capsule (a rectangle with semicircular ends)
   filled, from `(cx − 0.12 d, cy − 0.3 d)` to `(cx + 0.12 d, cy + 0.08 d)`;
   and stroked `0.06 d` wide with round caps, the lower half of a circle of
   radius `0.2 d` centred at `(cx, cy − 0.04 d)`, a line from
   `(cx, cy + 0.16 d)` to `(cx, cy + 0.3 d)` and a line from
   `(cx − 0.12 d, cy + 0.3 d)` to `(cx + 0.12 d, cy + 0.3 d)`;
3. the *label*: a text box (§8.2.4, laid out by §8.5.3) with the frame
   `[fx + 2p + d, fy + p, fw − 3p − d, fh − 2p]` (nothing when its width or
   height is not positive), `font` `sans`, `color` `#202124FF`, `align`
   `start`, `dir` `auto`, no `breaks`, and the runs: the recording's
   `title`, or `Recording` when it is empty or absent, bold, size 12; when
   the recording has a finite `duration`, ` · ` and the duration as `m:ss`
   (`h:mm:ss` from an hour), size 12; when it has a valid transcript (§8.3.2),
   a line break and the text of its segments joined by single spaces, size
   10, `color` `#5F6368FF`, `lang` the transcript's `language`, cut to its
   first 2 000 Unicode scalar values. Unlike a text item the label is
   clipped: a line whose bottom is below `fy + fh − p` is not drawn, nor
   any after it.

An item whose recording is missing is drawn as a placeholder (§8.5.2) and
reported as "recording missing". A transcript that is missing, unreadable or
invalid is left out of the label (reported); the card is still drawn. An
`audio` item counts toward an infinite page's extent and is cut across
export pages like an image.

Playing: a reader that plays audio plays the recording (§8.3.1) when the
item is tapped or its play control used, and may show the position and the
transcript as it plays (§8.3.2). A reader that cannot play shows the card.
A `pdf` export with attachments embeds the recording once however many
items show it (`docs/attachments.md` §10).

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
                  "type": "application/vnd.sempere.transcript+json" },
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
  snapshots. Every other field is immutable: a `setRecording` naming one, or
  `origin` or `clocks`, or giving `title` a non-string or `transcript` a value
  that is not a blob reference, is invalid (the revision is rejected); `null`
  resets `title` to absent. Unknown fields as in §7.5; like an item's (§8.2.2)
  they are registers, set by `setRecording` and stamped in `clocks`.
- Recordings merge as sets like items, with permanent tombstones (§5.4).

#### 8.3.2 Transcript

A transcript is a blob whose content is UTF-8 JSON (not compressed):

```json
{ "format": "sempere-transcript/1",
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

A transcript whose `format` is not `sempere-transcript/1`, or whose segments
or words break these rules (order, overlap, `start ≤ end`, words inside their
segment, confidences in 0…1), is invalid: readers treat it like a blob that
fails verification (reported, shown as missing, §8.1.4).

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
`rec` naming a recording that is not present refers to a present recording
whose `parent` names it (one re-created by a restore, §5.7; the first by
`(started, id)` if several), else it is ignored. `rec` is immutable, so this
is how links survive a recording being removed and restored.

### 8.4 Limits

Writers must stay within, and readers may reject anything beyond:

| What | Limit |
| --- | --- |
| blob content (any kind, including video) | 1 GiB (2^30 bytes) |
| transcript content | 64 MiB |
| text of one item | 65 536 UTF-8 bytes, 1 000 runs, 10 000 `breaks` |
| LaTeX source of a `math` item | 8 192 UTF-8 bytes; typeset only within 4 096 tokens and 64 levels (§8.2.8) |
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
renderer cannot draw, an `audio` item whose recording is missing (§8.2.9),
and an item of an unknown kind (§7.5), is drawn as a placeholder (a `math`
item falls back to its source first, §8.2.8): its frame (rotated) outlined 1 pt in
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

## 9. Untrusted input

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
| `recipientsTag`, `secretLink` (§2.1) | a value that is not a string of 64 lowercase hex digits is a tag that does not verify (tampered), never a parse error | `VaultManifest` |
| subsets tried to find the last verified list (§2.1) | up to 3 entries deleted, lists of at most 16 keys (C(16, ≤3) = 696 tags) | `RecipientsAuth.maxSearchDeletions` |
| blob collector state (device-local, §8.1.6) | 64 MiB | `BlobCollectorState` |
| identity file, device state | 1 MiB | `BoundedRead` |
| attachment blob file (§8) | 1 GiB of content plus 16 MiB of framing and age overhead | `BoundedRead` |
| `backup.json`, export manifest (`.sempere-export-*.json`) | 256 MiB | `BoundedRead` |
| files read at all | regular files only (no FIFOs or devices; symlinks followed in a vault, not in an imported package) | `BoundedRead` |
| JSON nesting | 512 levels (Foundation's decoder) | |
| names of skipped ops, fields and features reported (§7.4) | 64 characters each; 32 distinct per note (or vault), the rest counted together | `NewerContent.maxNameLength`, `.maxNames` |
| unknown fields kept verbatim (§7.5, §8) | 24 levels deep from the document root; 16 384 values per file | `JSONValue.maxDepth`, `.maxValues` |
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
| item frame (app canvas, hit testing) | every number finite, rotated corners within 200 000 pt; other items are not drawn or selectable | `ItemFrames.isDrawable` |
| curve samples per stroke | 64 per control point + 1024 (sparser beyond) | `RenderLimits.samplesPerPoint` |
| outline points per page | 40 M | `RenderLimits.maxOutlinePoints` |
| nib width | 1 000 pt (drawn no wider) | `RenderLimits.maxNibWidth` |
| paper ruling | 40 000 commands per band, 1 M per page (plain background beyond) | `RenderLimits.maxPaperCommands…` |
| PNG image | 40 M pixels by default | `PNGOptions.maxPixels` |
| image decoded for export (§8.2.5) | 100 M pixels (§8.4) and at most 1 024 per byte of the file + 1 M (a header cannot claim more than its data can hold); 64 MiB per image blob; a truncated JPEG scan decodes as far as its data goes | `ImageLimits` |
| items drawn per page | 10 000 (§8.4); the rest are reported, not drawn | `RenderLimits.maxItemsPerPage` |
| font file (font packs, render) | 64 MiB; 512 tables; composite glyphs 8 levels and 65 536 points; CFF subroutines 10 levels, 65 536 charstring operations, 48 operands; layout substitutions 2^20 steps, nested lookups 8 levels; any failure falls back to another font | `OpenTypeFont`, `CFFFont`, `GSUBApplier` |
| font-pack scan | 20 000 font files, 64 faces per collection | `FontLibrary` |
| notebook levels shown | 64 | `NotebookNode.maxDepth` |
| LaTeX source (`math`, §8.2.8) | 8 192 UTF-8 bytes (else the revision is rejected); typeset only within 4 096 tokens, balanced groups and 64 levels of nesting (else drawn as source text) | `MathSource.check` |
| PDF attachment (export, `SemperePDF`) | 1 GiB file; 10⁶ objects; 256 MiB per decoded stream, 1 GiB decoded per file; nesting and page-tree depth 64; 32 reference hops; 4 096 cross-reference sections; 16 filters per stream; encrypted files refused | `PDFLimits` |
| PDF page drawn as pixels (SVG, PNG) | 16 M pixels per page (drawn at a lower resolution beyond), 256 M per export (placeholders beyond) | `RenderLimits.maxBackgroundPixels…` |
| summary cache file (§10) | 64 MiB on disk, 256 MiB after gunzip; any failure discards it | `SummaryCache.maxFileBytes` |
| published summaries (§12) | 64 MiB on disk, 256 MiB after gunzip; unknown fields skipped, not kept; any failure ignores the file, a bad entry only that entry | `PublishedSummaries.maxFileBytes` |

Foundation's own parsers are not safe on hostile bytes on every platform:
on Linux, `PropertyListSerialization` crashes on a binary plist holding a
set, `ISO8601DateFormatter` dies in ICU on a long fraction, and `XMLParser`
crashes on an element name that is not UTF-8 or on a processing
instruction without data. The library parses dates and binary plists
itself and checks PROPFIND bodies before `XMLParser` sees them.
`Tests/FuzzSupport` fuzzes every parser above on each test run.

## 10. Per-device summary cache (outside the vault)

Not part of a vault and never stored in one: a reader may keep, per device,
the summaries of a vault's notes (title, tags, notebook, deleted flag, page,
stroke and recognised-page counts, the recognised text of each page for search, newest `wall`) so that listing the vault
again does not decrypt every note. The reference implementation keeps it in
the app's Application Support folder and, for the CLI, in
`$XDG_CACHE_HOME/sempere/` (default `~/.cache/sempere/`). Other readers need
not read or write it; it is documented because it is derived from the vault
secret and holds note metadata.

**Key and name.** With `vaultSecret` (§2) as HKDF-SHA256 input key material
(RFC 5869, empty salt):

```
key  = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 summary-cache key",  L = 32)
name = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 summary-cache name", L = 16)
file = lowercase hex(name) ‖ ".summaries"
```

The file name says nothing about the vault without its secret; a vault whose
secret rotates (§3.3) gets a new, empty cache, and the old file is never read
again.

**File.** `SMPS` ‖ `0x01` ‖ ChaCha20-Poly1305 sealed box (12-byte random
nonce ‖ ciphertext ‖ 16-byte tag) under `key`, with associated data
`SMPS` ‖ `0x01` ‖ the file name (UTF-8). The plaintext is `gzip(JSON)` of
`{"schema": N, "notes": …}`: per note id, the sorted file names of the
revisions the summary was made from, the summary and, optionally, the metadata
of each of those revisions that thinning needs (name, `wall`, `checkpoint`,
`session`, `asOf`, snapshot `included`; §5.8.4), used only when it names
exactly the entry's files. Its JSON shape is the
implementation's own and changes with `schema`.

**Validity.** Revision files are write-once and named by `(hlc, device,
seq)` (§5), so an entry is used only when the note's current revision file
names are exactly the entry's; anything else (a new, compacted or removed
revision) means the note is read again. Summaries of notes with unreadable
revisions are not stored. A file that is missing, too large, fails to
authenticate or decompress, does not parse, or has another `schema` is
ignored and replaced on the next write. Because entries trust file names, a
revision damaged in place after it was cached is reported only when the note
is opened, not in the listing.

### 10.1 Other per-device caches

A reader may keep other caches derived from a vault on a device, under the
same rules as §10: never in the vault, unreadable and unlinkable to the vault
without its secret, and never trusted over the vault. Each cache has a
*purpose* (lowercase ASCII letters and digits in hyphen-separated words, at
most 64 bytes) and a 5-byte magic. The purposes `summary-cache`,
`recipients` and `capture` are reserved: with them the derivations below
would give the keys of §10, §2.1 and §11.1 (the other info strings of §2.1
contain a space, which no purpose can). With `vaultSecret` as
HKDF-SHA256 input key material (empty salt):

```
key      = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 <purpose> key",   L = 32)
entryKey = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 <purpose> entry", L = 32)
name     = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 <purpose> name",  L = 16)
folder   = lowercase hex(name)
entry    = lowercase hex(first 16 bytes of HMAC-SHA256(entryKey, label)) ‖ suffix
```

where `label` is the implementation's description of the entry (for example
a note id and its revision file names). Each entry file is `magic` ‖
ChaCha20-Poly1305 sealed box (12-byte random nonce ‖ ciphertext ‖ 16-byte
tag) under `key`, with associated data `magic` ‖ the entry's file name
(UTF-8), so an entry renamed or copied over another fails to open. A file that
is missing, too large or fails to open is a miss. A vault whose secret rotates
(§3.3) derives another folder; the old one is never read again and may be
deleted.

The reference app keeps one such cache, the **drawing cache** (purpose
`drawing-cache`, magic `SMPD` ‖ `0x01`), in its Caches folder: per note
*version* (the note id and the sorted file names of its revisions, which
identify its content because revision files are write-once, §5), the note's
state without stroke geometry (a JSON `layout`) and, per page, PencilKit's
`dataRepresentation` of the page's ink, one canvas stroke per stored stroke.
Its contents are the implementation's own, change with its schema number, and
are checked against the revisions read from the vault before they are drawn
on. It is limited in size (least recently used entries go first) and deleted
when the vault is closed on that device.

It keeps four more, under the same derivation:

- the **render cache** (purpose `render-cache`, magic `SMPI` ‖ `0x01`):
  pictures of image items and previews of PDF page items as drawn on that
  device, labelled by everything the pixels depend on (the item's drawing
  fields, the blob reference, the scale), sealed as above; limited in size and
  deleted when the vault is closed;
- the **attachment index** (purpose `attachment-index`, magic `SMPX` ‖
  `0x01`, one entry per note named `entryName("note|<note id>")` plus
  `.idx`, in Application Support): per note, the blob files of `att/`, the
  blob references of each revision by file name, the hashes the current
  state shows, and this device's first-seen-unreferenced times for §8.1.6
  rule 4 (`docs/attachments.md` §4). Losing it only restarts those windows;
  collection reads the note again before deleting anything;
- the **activity** file (purpose `activity`, magic `SMPA` ‖ `0x01`, one entry
  named `activity`, not keyed by `entryName`): the notes "Recognize All" read in
  the last seven days and the recent search queries, kept across launches;
- the **blob cache** (purpose `blob-cache`): decrypted attachment content
  (§8.1), which PDF and image readers need as plain files, so its entries are
  **not** sealed: each file holds a blob's verified content, is named
  `entryName("blob|<note id>|<sha256>|<size>")` plus a type extension, and is
  protected only by the device's file protection. A file found there from an
  earlier session is used only after its size and SHA-256 match the
  reference again; the folder is deleted when the vault is closed. Audio and
  transcripts are not kept: their files are deleted as soon as nothing plays
  or reads them. Where the
  system does not encrypt files at rest (Mac Catalyst has no data protection
  class), files are never kept across launches: a launch deletes what an
  earlier one left before using the folder.

## 11. Capture inbox

*New: quick capture.* A device may add voice notes to a vault without its
identity and without the vault secret: it keeps the vault's public
recipients and a **capture key**, and seals each voice note into `inbox/`.
Any device that can read the vault later **adopts** it: it becomes a note,
written as ordinary revisions and blobs (§5, §8). Files under `inbox/` are
not revisions and are not write-once: they are deleted once adopted. Readers
that do not implement this section ignore `inbox/` (§1); no `features` entry
is needed, since nothing under `notes/` changes. Rationale and threat model:
`docs/quick-capture.md`.

### 11.1 Capture key

```
captureKey = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 capture key", L = 32)
```

It authenticates inbox files and nothing else. It cannot decrypt anything,
tag a revision (§4), name a blob (§8.1.2) or derive a per-device cache key
(§10), and HKDF does not reveal the secret. It changes whenever the secret
rotates (a recipient is removed, §3.3), which revokes every capture key handed
out before. Inbox files already there when the secret rotates are not lost:
the recipient change re-tags each one that verifies under the outgoing
capture key and re-encrypts it to the new recipients (§3.3.1 step 3), as it
does when a recipient is added; a file sealed with a revoked key after that
never verifies. A capturing device stores the key and the recipients list (a
*capture profile*); how it stores them is up to the implementation. The list
comes from a vault whose recipients checked (§2.1) when the profile was made
or refreshed; a tampered list is never put in a profile, and a capturing
device seals to its profile's list only, never to the `recipients` it may
read from `vault.json` without the secret.

### 11.2 Inbox files

`inbox/<captureId>.<kind>.age`, with `<captureId>` a lowercase UUID and
`<kind>` `capture` or `transcript`. Other names are unknown files. Each file is
an age v1 file encrypted to the vault's recipients, like a revision. Its
plaintext is:

| Offset | Size | Content |
| --- | --- | --- |
| 0 | 4 | ASCII `SMPC` |
| 4 | 1 | version `0x01` |
| 5 | 32 | tag = HMAC-SHA256(key = captureKey, message = `"sempere/1" ‖ 0x00 ‖ "capture" ‖ 0x00 ‖ filename ‖ 0x00 ‖ rest`) |
| 37 | rest | one line of UTF-8 JSON (no `0x0A` inside), `0x0A`, then the payload |

`filename` is the file's base name, so a file renamed to another capture id or
kind does not verify. A reader verifies the tag (under the current secret's
capture key, or the previous secret's during an unfinished rewrap, §3.3.1)
before it parses anything after it, and treats a file that fails as
untrusted input (§9): reported, kept, never adopted. The whole plaintext is at
most 256 MiB.

- **`capture`**: the JSON is the capture manifest and the payload is the
  audio, as recorded:

  ```json
  { "format": "sempere-capture/1", "id": "<captureId>", "device": "a1b2c3d4",
    "vault": "<vaultId>", "created": "2026-10-07T14:33:05.120Z",
    "started": "2026-10-07T14:32:41.000Z", "title": "Voice note 7 Oct 2026, 14:32",
    "notebook": "Inbox",
    "audio": { "sha256": "…", "size": 196608, "type": "audio/mp4" },
    "duration": 24.1, "codec": "aac", "sampleRate": 48000, "channels": 1, "bitRate": 64000 }
  ```

  `id` must equal `<captureId>` and `vault` the vault's `vaultId`. `audio` is
  a blob reference (§8.1.1) of the payload: its size and SHA-256 must match.
  `device` is the capturing device's id (§5). `title`, `notebook` (absent:
  `Inbox`) and the informational fields become the note's.
- **`transcript`**: the payload is the 64 lowercase hex digits of the
  capture's audio SHA-256 (its manifest's `audio.sha256`). That binds the
  transcript to the audio: the capture key is on every capturing device and
  capture ids are in the clear, so otherwise any holder of the key could add
  a transcript to a voice note it never heard. A reader adds a transcript
  only to the recording whose blob has that hash, and never one whose
  payload is anything else (an empty payload was written before this rule):
  such a transcript is deleted once its note exists, never adopted. The JSON
  is a transcript (§8.3.2) whose `recording` is the
  capture's recording id (§11.3); the payload is empty.

Recovery without the app (the audio of a capture):

```
age -d -i key.txt inbox/ID.capture.age | tail -c +38 | head -n 1 | jq .   # the manifest
age -d -i key.txt inbox/ID.capture.age | tail -c +38 | tail -n +2 > note.m4a
```

### 11.3 Adoption

The note, its page and its recording have ids derived from the capture id,
`derived(name)` being the first 16 bytes of SHA-256 of the UTF-8 `name` with
the UUID version set to 8 and the variant to `10` (RFC 9562):

```
note      = derived("sempere-capture/1 <captureId> note")
page      = derived("sempere-capture/1 <captureId> page")
recording = derived("sempere-capture/1 <captureId> recording")
```

so devices that adopt the same capture concurrently write the same note, and
an adoption interrupted before the inbox file was deleted adds nothing when
repeated. To adopt, a reader verifies the files (§11.2), writes the audio
(and transcript) as blobs of the note (§8.1.4), then writes one delta as
itself (its own device id and clock):

- a note that does not exist yet gets `newNote` (title, notebook, one page
  with the derived page id, the reader's default paper and page size) and
  `addRecording` (the derived recording id, the blob, `started` and the
  informational fields), with `transcript` set when a transcript file is
  there;
- a note that exists gets only `setRecording(transcript)`, and only when the
  recording is there without a transcript and its blob is the audio the
  transcript is bound to (§11.2).

Afterwards the capture file is deleted once the note exists, and the
transcript file once the recording has a transcript (or is gone, or holds
other audio than the transcript is bound to, §11.2). A
transcript file whose capture has not arrived yet stays.


## 12. Published summaries

*New: web viewer.* A vault may hold, at its root, `sempere-summaries.sealed`:
the summary of each note (title, tags, notebook, flags, page count and the
searchable text of each page) together with the names of the revision files
it was made from, so that a reader can list and search the vault without
decrypting every revision. It exists for readers that start cold on every
visit, such as the web viewer (`docs/web-viewer.md`), and is published next
to a copy of the vault (a WebDAV mirror) rather than kept per device like
the cache of §10.

The file is **a hint**. It is derived from the revisions, never needed to
read the vault, and never trusted over them: a reader that does not
implement this section ignores it (§1), and a missing, stale, damaged or
foreign file is never an error, only a slower listing. It is not under
`notes/` and is not write-once: a writer replaces it whole (atomically, or
with one `PUT`). It needs no `features` entry (§2).

### 12.1 Key and file

```
key = HKDF-SHA256(ikm = vaultSecret, salt = "", info = "sempere/1 published summaries key", L = 32)
```

| Offset | Size | Content |
| --- | --- | --- |
| 0 | 4 | ASCII `SMPU` |
| 4 | 1 | version `0x01` |
| 5 | 12 | nonce, random per write |
| 17 | rest | AES-256-GCM ciphertext under `key`, then its 16-byte tag |

The associated data is the first 5 bytes ‖ `"sempere/1"` ‖ `0x00` ‖ the
vault's `vaultId` (§2, lowercase, ASCII). The plaintext is `gzip(JSON)`
(UTF-8). AES-GCM rather than the ChaCha20-Poly1305 of §10 because browsers
provide it (WebCrypto); with a random 96-bit nonce per write and one write per
change of the vault's listing, nonce reuse is not a concern. Only holders of
the vault secret (the vault's recipients) can write or read the file. A
vault whose secret rotates (§3.3) derives another key, so its old file no
longer opens and is ignored until rewritten; during an unfinished rewrap a
reader may also try the previous secret's key.

Test vector (`vaultSecret` = 32 bytes `0x00 0x01 … 0x1f`, `vaultId`
`0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c`, nonce 12 bytes `0xa0 0xa1 … 0xab`,
plaintext the ASCII bytes `{}` (not gzip, to keep the vector short)):

```
key  = 4ffd10840df4dc46092a2c424919f611c1bcc355fe7526a19e25a1489bf5510a
file = 534d505501a0a1a2a3a4a5a6a7a8a9aaabb466bcf027fe45b94f3fe195f6e0b57d9c6e
```

### 12.2 Content

```json
{
  "format": "sempere-summaries/1",
  "vaultId": "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c",
  "notes": {
    "6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10": {
      "revisions": ["17596320000000000-a1b2c3d4-1.delta.age",
                    "17596952000000000-a1b2c3d4-2.delta.age"],
      "title": "Groceries",
      "tags": ["home"],
      "notebook": "Personal/Lists",
      "favorite": false,
      "deleted": false,
      "created": "2026-10-04T16:20:00.000Z",
      "modified": "2026-10-06T09:12:44.512Z",
      "pages": 2,
      "pageTexts": [{ "page": 1, "text": "milk eggs" }]
    }
  }
}
```

- `format` is `sempere-summaries/1` and `vaultId` the vault's; a file with
  another value of either is ignored.
- `notes` maps a note id (a lowercase UUID, the note's directory name) to its
  entry. A writer includes only notes whose listed revisions it read
  completely and could reconstruct (§5.3); a note with an unreadable revision,
  or with content of a newer format version it does not understand (§7.4),
  has no entry.
- `revisions`: the file names of every revision of the note the summary was
  made from (canonical names, §5), sorted, at least one.
- The rest describes the note's state (§5.4) merged from exactly those
  revisions: `title`; `tags` (the current tags, §5.4.1); `notebook`, absent
  when the note has none; `favorite`; `deleted`; `created`; `modified`, the
  greatest `wall` (§5.1) among the revisions; `pages`, the number of pages;
  `pageTexts`, for each page with searchable text, its 1-based position and
  that text: the page's recognised text (§5.5), then the text of each text
  item (§8.2.4), the `pageText` of each PDF page item (§8.2.6) and the LaTeX
  source of each math item (§8.2.8) in drawing order (§8.2.3), the non-empty
  ones joined by `\n`, in page order. Pages
  without such text are left out. Dates are as in §6.

Unknown fields are ignored. Writers emit no others under `format`
`sempere-summaries/1`; a change readers must not misread changes `format`.

### 12.3 Reading

A reader uses an entry only when the note's revision file names in its own
listing of the vault are exactly the entry's `revisions`. Revision files are
write-once and named by `(hlc, device, seq)` (§5), so the same names are the
same revisions and the same summary. For any other note (a new, compacted or
removed revision, no entry, or an entry that does not validate) it reads the
revisions as usual; entries of notes the listing does not have are ignored.
A reader may show the entries before its listing is complete, as long as it
replaces each one that turns out not to match.

The whole file is ignored when it is missing, larger than its limit (§9),
does not start with `SMPU` `0x01`, fails to authenticate, does not gunzip or
parse, or has another `format` or `vaultId`. An entry whose id, `revisions`
or any field above is malformed is ignored alone.

Trust. The file is authenticated under the vault secret, so a storage server
cannot forge or alter an entry; it can withhold the file or serve an older
one, whose entries then either still match (unchanged notes) or are read
again. A malicious recipient, who can also write revisions, can write
entries that disagree with the revisions; a reader shows what the revisions
say once it opens a note, and prefers that summary from then on.

### 12.4 Writing

`sempere vault summaries` writes the file (docs/cli.md); `sempere sync
webdav` keeps the server's copy current, computed from what the server holds
after the sync. The file is never copied between the two sides of a sync:
each writer computes it from its own listing. The app does not write it.
