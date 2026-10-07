# The `sempere` command line

The Linux and macOS face of Sempere: keys, vault management, note editing,
verification, export and recovery. Everything the app does to vault data can
be done here and scripted with `--json` (the CLI-first rule in `CLAUDE.md`);
only the drawing itself needs the app. It builds with `swift build -c release --product sempere`
and CI publishes a static Linux binary. The executable only parses arguments,
talks to the terminal and sets exit codes; everything else lives in
`Sources/Sempere` and `Sources/SempereRender`.

## Global conventions

| Option | Meaning |
| --- | --- |
| `--vault PATH` | The vault directory (`*.sempere`). Env `SEMPERE_VAULT`. |
| `--identity FILE` | An age identity file (`age-keygen` style). Repeatable. Env `SEMPERE_IDENTITY` (one path). |
| `--passphrase-env VAR` | Name of the environment variable holding the passphrase of the vault's stored key file. |
| `--json` | Machine-readable output where it makes sense (everything except `recover`, `keys generate` without `--out`, and `keys export` without `--out`). |
| `-q`, `-v` | Quieter (data only, or only problems) / more detail. |
| `--version`, `--help` | On every command. |

`--vault`, `--identity` and `--passphrase-env` apply to the commands that open
an existing vault. Times are printed in your local time zone with an offset;
`--json` uses UTC (`Z`).

**Getting a key.** Commands that read notes need an identity. In order:
`--identity` files (or `$SEMPERE_IDENTITY`); otherwise the passphrase-wrapped
key stored in the vault's `keys/` directory, unlocked with the passphrase from
`--passphrase-env VAR`, else `$SEMPERE_PASSPHRASE`, else a no-echo prompt on
the terminal. A passphrase never goes on the command line. Secret keys are
printed only by `keys generate`, `keys export` and `keys paper` (into its PDF).

**Exit codes**

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Generic failure (I/O, bad input, corrupt file, refusing to overwrite). |
| 2 | Usage error (unknown option, missing vault, bad recipient string). |
| 3 | `vault verify` or `backup verify` found problems, a restored vault is not healthy, or a recipient change is incomplete. |
| 4 | Cannot decrypt: wrong key or passphrase, or no key available (no identity, no passphrase and no terminal to ask, or a `--passphrase-env` variable that is not set). |
| 5 | Legacy vault: it still lists a classic X25519 key, so it may only be migrated. The message names the command: `migrate first: sempere vault recipients replace OLD NEW`. |

**Legacy vaults** (format.md §3.3.2) are migrate-only. On a vault that lists a
classic X25519 recipient, alone or next to post-quantum ones, only these run:
`vault info`, `vault recipients add` (post-quantum key) / `remove` /
`replace`, `vault rewrap-resume`, and `recover` (the stock-`age` equivalent,
which reads one file and needs no migration). Every other command that opens
a vault (`notes …`, `notebooks …`, `tags …`, `pages …`, `export`, `search`, `compact`, `snapshot`, `import`,
`vault verify`, `keys export`, `keys paper --vault`, `sync webdav`,
`backup --prune`, `backup verify`, `restore`) exits 5 before asking for a key
or passphrase. `backup V --to DIR` (without `--prune`) and `backup V --archive`
are allowed too: they copy the encrypted files without decrypting anything,
and a copy before migrating is a good idea. `restore` is refused because it
would hand back a legacy vault; migrate the backup folder (itself a vault)
first. `keys generate` and `keys show` do not touch a vault.

Errors go to stderr, one line each, prefixed `sempere:`.

**Environment**

| Variable | Use |
| --- | --- |
| `SEMPERE_VAULT` | Default for `--vault`. |
| `SEMPERE_IDENTITY` | Default identity file. |
| `SEMPERE_PASSPHRASE` | Passphrase for the vault's stored key file, for scripts and tests. |
| `SEMPERE_PDFTOPPM` | Poppler's `pdftoppm` for PDF page backgrounds in SVG/PNG exports (default: `pdftoppm` on `PATH`). |
| `XDG_STATE_HOME` | Where `device.json` lives (default `~/.local/state`). |

## Commands

### Keys

```
sempere keys generate [--out FILE]
sempere keys show FILE
sempere keys export --vault V [--recipient age1...] [--out FILE]
sempere keys paper --out KIT.pdf [--identity FILE] [--vault V] [--passphrase [--work-factor 15...18]]
                    [--paper letter|a4]
```

- `generate` writes an `age-keygen`-style identity (mode 0600, refuses to
  overwrite) and prints the public key. Without `--out` the identity goes to
  stdout and the public key to stderr. Keys are always post-quantum
  MLKEM768-X25519 (`AGE-SECRET-KEY-PQ-1...`, recipient `age1pq1...`, as
  `age-keygen -pq` makes); vaults take no other kind. Decrypting their files
  with the stock CLI needs `age` 1.3 or later; on Apple platforms the key
  type needs macOS 26.
- `show` prints the public key (`age1...` or `age1pq1...`) of an identity file.
- `export` decrypts the vault's passphrase-wrapped key file
  (`keys/<key-name>.key.age`, format.md §3.2) to a plain identity file, to move a key to
  another device. `--recipient` is needed only if the vault stores several.
- `paper` writes a two-page printable PDF recovery kit (mode 0600, refuses to
  overwrite). Page 1: the key as a QR code (byte mode, error correction Q,
  version 6 for an `AGE-SECRET-KEY-1…` line), the key as text in numbered
  lines grouped by 5 with a 4-digit checksum per line, the public key, and with
  `--vault` the vault name, id and creation date; a boxed warning that **the
  sheet is the key**. Page 2: recovery step by step with stock tools
  (`age -d -i key.txt FILE.age | tail -c +38 | gunzip | jq .`, a loop that dumps
  every note's newest snapshot) and with `sempere restore` / `export`.
  The line checksum is the first 4 hex digits of SHA-256 of the line as typed:
  `printf '%s' 'LINE' | sha256sum | cut -c1-4`. The key also carries its own
  Bech32 checksum (its last 6 characters, a BCH code over the whole key): any
  typo of up to 4 characters makes `age` reject it, but only the line checksums
  say which line is wrong; `age-keygen -y key.txt` must print the public key on
  the sheet. With `--vault` the key must be one of the vault's recipients
  (else exit 4). Without `--identity` the key comes from the vault's stored key
  file (passphrase as for any command).
  `--passphrase` prints a passphrase-wrapped copy of the key instead (armored
  age, scrypt, `--work-factor` default 18; QR error correction M). It wraps only
  the secret key line, so a post-quantum key's 1959-character public key never
  ends up in the QR code (it would not fit). The passphrase is the one of the
  vault's stored key file for this key (checked by opening it), otherwise one
  you choose (`--passphrase-env VAR` / `$SEMPERE_PASSPHRASE` / the terminal,
  confirmed). Either way the command decrypts what it prints before writing the PDF.
  That sheet is safe to store less carefully, but useless without the
  passphrase. `--json` emits `path`, `variant` (`plain` or `passphrase`),
  `publicKey`, `vaultId`, `qrVersion`, `qrErrorCorrection` and `lines`.
  Delete the PDF once it is printed.

  **Post-quantum keys** (`AGE-SECRET-KEY-PQ-1…`, 77 characters, from
  `age-keygen -pq`): the same sheet. Kits are printed only for post-quantum
  keys: a classic `AGE-SECRET-KEY-1…` key is refused ("create a new key", exit
  2), and so is a legacy vault given with `--vault` (exit 5). The first line is the `AGE-SECRET-KEY-PQ-1`
  prefix, then 58 characters in lines of 20, and the QR code is version 7 at
  level Q (45×45 modules, against version 6 for an X25519 key). The public key is 1959 characters and cannot be
  read or typed from paper, so the sheet prints its first characters, its length and
  the first 16 hex digits of its SHA-256 instead; page 2 gives
  `age-keygen -y key.txt | tr -d '\n' | sha256sum | cut -c1-16` to check the rebuilt
  key against it. Page 2 also says that `age` 1.3 or newer is needed (Ubuntu's apt
  package is older). `backup`, `restore` and the archive copy `keys/*.key.age`
  whatever the file name, so the hash-named key files of post-quantum recipients
  (`age1pq-<64 hex>.key.age`) are included.

### Vault

```
sempere vault init PATH --recipient age1... [--recipient ...] [--label TEXT ...]
                         [--store-key FILE [--passphrase-env VAR] [--work-factor 15...18]]
sempere vault info
sempere vault recipients add age1pq1... [--label TEXT] [--rewrap header|reencrypt] [--store-key FILE [--store-passphrase-env VAR] [--work-factor 15...18]]
sempere vault recipients remove age1... [--rewrap header|reencrypt]
sempere vault recipients replace age1old... age1pq1new... [--label TEXT] [--rewrap header|reencrypt] [--store-key FILE ...]
sempere vault rewrap-resume
sempere vault verify
sempere vault index [--out PATH|-]
```

- `init` creates the vault. `PATH` must end in `.sempere`. Give no `--label`
  or one per `--recipient`. `--store-key` also writes that identity,
  passphrase-wrapped, into `keys/` (the passphrase is confirmed when typed).
- `info` prints vault id, creation time, recipients with labels, number of
  notes, stored key files, whether a recipient change is pending and whether
  its journal is readable. It works without a key (the journal check then says
  "not checked"); with an identity or a scripted passphrase it checks it.
- `recipients add` / `remove` rewrap every file to the new recipient set
  (`remove` also rotates the vault secret) and print a report. If any file
  cannot be rewrapped the exit code is 3 and the message says to run
  `rewrap-resume`. Removing a key does not revoke what it already decrypted.
- Attachment blobs (`notes/<id>/att/`, `format.md` §8.1.5) are rewrapped
  too. By default an `add` rewrites each blob's age header only (same file
  key, payload copied), and a `remove` or `replace` (or an `add` that changes
  the key types, such as a post-quantum key added to a legacy vault)
  re-encrypts each blob under a new file key; a removal also renames every
  blob under the new vault secret. `--rewrap header|reencrypt` overrides the
  method for this change. `header` on a removal is faster but leaves every
  old copy of a blob (backups, file-version history) able to open the current
  file with the removed key. The method is recorded in the journal, so
  `rewrap-resume` (from any device) finishes with the same one. `--json`
  reports it as `blobs`.
- Recipients must be post-quantum (`age1pq1...`): `init`, `recipients add`
  and the new key of `replace` refuse a classic `age1...` key with "create a
  new key" (exit 2), before asking for any passphrase. Legacy vaults that
  still list X25519 keys open as before and are migrated with `replace` or
  `add` + `remove` (format.md §3.3.2). A classic identity given to a
  post-quantum vault fails with the same advice (exit 4).
- `recipients add` / `replace --store-key FILE` also store the new
  recipient's identity (FILE, which must be that key) passphrase-wrapped in
  `keys/`, with the passphrase from `--store-passphrase-env VAR`, else
  `$SEMPERE_PASSPHRASE`, else the terminal (confirmed). Use it when the
  vault is unlocked by passphrase: only key files of current recipients are
  offered for passphrase unlocking, so after a `replace` the old key file
  (left in `keys/`) no longer is.
- `recipients replace` swaps one recipient for another with a single rewrap
  and a secret rotation: the post-quantum migration (format.md §3.3.2). An
  interrupted replace is finished by `rewrap-resume` with **both** keys
  (`--identity OLD --identity NEW`), so keep the old key until `info` shows
  no pending rewrap.
- Recipient arguments may be the key itself or a file holding it: a
  recipients file (first non-comment line) or an identity file, of which only
  the `# public key:` line is read. Post-quantum recipients are 1959
  characters, so files are handier.
- `info` abbreviates post-quantum keys, shows each recipient's type
  (`x25519` / `mlkem768x25519`, `type` in `--json`) and a `Post-quantum:`
  line: `yes` only when no X25519 recipient is left.
- `rewrap-resume` finishes an interrupted change.
- `verify` decrypts, tag-checks and decodes every file and prints
  `status  path` per file plus counts. Exit 0 only if the vault is healthy,
  else 3. `-q` lists only problem files. `--json` emits `healthy`,
  `manifestProblems`, `rewrapPending`, `journalProblem`, `counts` and `files`.
  Attachment blobs are decrypted and hashed in full: `ok`, `unreferenced`
  (healthy: no revision of its note uses it; `blobs gc` removes it later),
  `invalid` (bad framing, padding, hash or name), `staleRecipients`, and a
  `missing` line for each reference with no blob.
- `index` writes `sempere-index.json` at the vault root (or `--out PATH`;
  `--out -` prints it): every note id and its revision file names, the
  listing the web viewer reads on a static server that cannot list folders
  (`docs/web-viewer.md` "Hosting"). It needs no key and holds only names that
  storage already shows. Once it exists it is kept current automatically:
  every command that opens the vault rewrites it when the listing changed (a
  failure to do so is a warning), and `sync webdav` rewrites the server's
  copy when the server has one. A WebDAV share needs no index. Legacy vaults are refused (exit 5), as the
  viewer cannot read them. `--json` emits `path`, `notes` and `revisions`.

### Attachments

```
sempere blobs list [NOTE ...]
sempere blobs verify [NOTE ...]
sempere blobs extract NOTE SHA256 [--out FILE]
sempere blobs add NOTE FILE --type MEDIA/TYPE
sempere blobs copy SHA256 --from NOTE --to NOTE
sempere blobs unused [NOTE ...] [--retention DAYS]
sempere blobs gc [NOTE ...] [--dry-run] [--retention DAYS]
sempere blobs repair [NOTE ...]
```

Blobs hold the bytes of images, PDFs, recordings and transcripts, one
encrypted file per content per note: `notes/<id>/att/<keyed hash>.<kind>.age`
(`format.md` §8.1). Revisions reference them by SHA-256; a note never uses
another note's blobs. NOTE is an id or a title; without one, every note.

- `list` shows each blob (kind, size on disk, referenced or not) and every
  reference with no blob (`MISSING`), unreadable revisions and unknown files.
  It reads the revisions but decrypts no blob.
- `verify` decrypts and checks every blob of the notes (as `vault verify`
  does, restricted to blobs). Exit 3 unless every blob is `ok` or
  `unreferenced`.
- `extract` writes the verified content of the blob a revision of NOTE
  references (SHA256, or a unique prefix of at least 8 digits). With `--out`
  the file appears only once the whole content has verified and is never
  overwritten; on standard output content streams as it is decrypted, so on
  an error (exit 1) discard what was printed.
- `add` stores a file as a blob of NOTE (streaming, any size up to 1 GiB) and
  prints the reference to put in a revision (`{"sha256", "size", "type"}`;
  `-q` prints only the hash). It adds no item; until a revision references
  the blob it is unreferenced. The first blob adds `features: ["attachments"]`
  to `vault.json`.
- `copy` copies a blob that NOTE `--from` references into NOTE `--to` (a byte
  copy, verified as it is read), before a revision there uses it.
- `unused` lists blobs no revision of their note references, with the date
  each may be collected. Read only.
- `gc` deletes those that have been unreferenced for `--retention` days
  (default 30), per `format.md` §8.1.6: per note, only when every revision of
  the note was read and verified, no recipient change is pending, no revision
  (deleted notes and old restore points included) references the blob, and
  this device first found it so at least the window ago. The first sighting
  is recorded in `$XDG_STATE_HOME/sempere/blobs/<vaultId>.json` (default
  `~/.local/state/...`), never in the vault; a blob that becomes referenced
  again loses its record. A blob is decrypted and verified in full before it
  is deleted; one that cannot be is reported and kept. `--dry-run` deletes
  and records nothing. Exit 3 when a note could not be collected (unreadable
  revision, pending rewrap) or a blob could not be verified.
  Collection never happens as a side effect of `compact`, `sync` or opening.
- `repair` fixes blobs a recipient change by an older build left behind
  (still named under an old vault secret, encrypted to old recipients, or
  under the wrong kind): each is verified, re-encrypted to the current
  recipients and renamed. Only authentic blobs are touched (the name verifies
  under the current secret, or a verified revision of the note references the
  content); anything else is listed and left alone (exit 3).

`recover` also reads a single blob file without the vault (see "Recover").

#### Adding attachments

```
sempere attach image NOTE FILE [--page N] [--frame X,Y,W,H | --at X,Y [--width W]] [--crop X,Y,W,H]
                               [--rotation DEG] [--layer content|background] [--keep-metadata]
                               [--rec RECORDING [--rec-at SECONDS]] [--dry-run]
sempere attach pdf NOTE FILE [--pages 1-3,5,7-] [--after N]
                             [--page N [--frame ... | --at ... --width ...] [--crop X,Y,W,H]] [--dry-run]
sempere attach text NOTE (TEXT | --file FILE|-) [--page N] [--frame ... | --at ... --width ...]
                             [--font sans|serif|mono] [--size PT] [--color #RRGGBB[AA]]
                             [--align start|center|end|left|right] [--bold] [--italic] [--lang TAG]
                             [--layer content|background] [--rec RECORDING [--rec-at SECONDS]] [--dry-run]
sempere attach recording NOTE FILE [--title T] [--started TIME] [--type MEDIA/TYPE] [--duration S]
                             [--codec NAME] [--sample-rate HZ] [--channels N] [--bit-rate BPS]
sempere attach transcript NOTE RECORDING FILE [--dry-run]
```

The commands the app's add flows have, scriptable (`docs/attachments.md` §14
task F). Each stores the file's bytes as an encrypted blob of the note
(`blobs add` does the same without a placement), then writes **one delta**
through the same `NoteOps` the app uses, with this machine's device id and
clock (as `snapshot`). NOTE is an id, an id prefix or an exact title; a
deleted note is refused. Pages are numbered from 1 as `pages list` prints
them (`--page` defaults to 1); coordinates are points from the page's top-left.
Standard output is the new item's (or recording's) id, one per line, so
`ID=$(sempere attach image …)` works; the confirmation goes to standard error
(`-q` silences it). `--json` prints `{note, file, dryRun, blob, items,
recording, pagesAdded}`: `file` is the delta written (`null` with `--dry-run`),
`blob` the reference stored (`sha256`, `size`, `type`), `items` the added items
as `notes show --json` prints them (`{page, pageId, item}`), `recording` the
recording added or changed. `--dry-run` checks the file and the placement and
says what would be added; it writes neither the blob nor a delta. A blob
stored before a failing delta is unreferenced; `blobs gc` collects it. Nothing
is stored when the file or the placement is refused (exit 1; bad options are
exit 2).

- `image` takes a JPEG or PNG. The stored bytes have location and camera
  metadata removed (every APPn segment but JFIF, ICC and Adobe, and comments,
  in a JPEG; ancillary chunks but the colour ones in a PNG) unless
  `--keep-metadata`; a JPEG's EXIF orientation is first copied to the item's
  `orientation`, so it still shows upright (`format.md` §8.2.5). HEIC, WebP,
  GIF, TIFF and CMYK or arithmetic-coded JPEGs are refused: convert them first.
  The file must decode, stay under 100 megapixels and 64 MiB. Without a frame
  the image is shown at one pixel per point, shrunk to fit inside a 36 pt
  margin, centred across the page and a margin from its top; `--at` and
  `--width` set its corner and width (the height follows the aspect of the image
  or its `--crop`, given in oriented pixels), `--frame` all four numbers.
  `--rotation` is degrees clockwise. Items stack in the order they are added
  (each gets a `z` above the layer's others); `--layer background` puts the image
  under the page's other items.
- `pdf` stores the PDF once and places pages of it (`--pages`, default all;
  the list keeps its order). By default each selected page becomes a **new note
  page** with the PDF page as a background that fills it (layer 0; fitted and
  centred when its size differs from the note's page size), inserted after note
  page `--after` (0: before the first; default the end), all in one delta.
  The note's page size is not changed, and a pageless note takes no inserted pages.
  With `--page` (and `--frame`, or `--at` and `--width`, and `--crop` on the
  effective page) **one** PDF page is instead placed as a figure on an existing
  page, in the content layer; `--pages` must then select exactly one. Encrypted
  PDFs, files that are not PDFs, PDFs with more than 2 000 pages or a page
  without a usable size are refused. Annotations and form fields are not drawn
  (`format.md` §8.2.6).
- `text` adds a text box. The text is the argument, or `--file` (`-` is standard
  input), at most 65 536 bytes of UTF-8, stored as NFC with `\n` line breaks in
  one style (one trailing newline of a file is dropped). Without a frame the box
  is as wide as the page inside a 36 pt margin (or `--width`), a margin from
  the top and left (or `--at`). The text is laid out with the fonts `export`
  uses (bundled Noto and font packs) and the soft line breaks are **stored**
  (`breaks`, `format.md` §8.2.4, §8.5.3), so the app, the app's exports and
  `sempere export` break it into the same lines; without `--frame` the box is
  as tall as those lines at 1.2 × `--size` (default 14), a `--frame` keeps its
  height. `--no-breaks` stores none (each renderer then wraps the text with its
  own fonts); without usable fonts the CLI warns and stores none. `--lang`
  picks fonts for CJK text. Typed text is searchable (`search`).
- `recording` stores an audio file and adds it to the note. MPEG-4 audio (`.m4a`;
  AAC-LC, HE-AAC or ALAC, `audio/mp4`) is read for its duration, codec, sample
  rate, channels and average bit rate; each option overrides what was read.
  Another format needs `--type audio/…` (stored and listed, perhaps not playable
  in the app). `--started` is the wall time of the first sample (RFC 3339);
  without it the file's modification time minus its duration. At most 1 000
  recordings per note. `--rec ID` on `image` and `text` links an item to a
  recording (id, id prefix of 4+ characters or exact title) at `--rec-at` seconds
  (`format.md` §8.3.3).
- `transcript` sets a recording's transcript from a `sempere-transcript/1` JSON
  file (`format.md` §8.3.2). The file is checked (format, segment order and
  times, confidences, and that it names the recording by id); it replaces any
  transcript the recording has, in one `setRecording` delta.


### Backup and restore

```
sempere backup [V] --to DIR [--prune] [--checksum]
sempere backup [V] --archive FILE.tar
sempere backup verify DIR [--identity FILE]
sempere restore DIR --to NEWPATH.sempere [--identity FILE]
```

`V` is the vault (else `--vault` / `$SEMPERE_VAULT`). Backups only ever hold
the encrypted files: nothing is decrypted to disk, and no key is needed except
for `--prune` and for a full `verify`.

- `backup V --to DIR` keeps `DIR` an up-to-date copy of the vault. `DIR` is
  created if needed; an existing `DIR` must be a backup of the same vault (or
  empty). Every file is written atomically (temporary file in the same
  directory, `fsync`, rename) and read back to compare its SHA-256 with the
  source. Revision files are write-once, so a later run copies only new ones
  and skips a file whose size and recorded hash already match (`--checksum`
  re-hashes them all). That size shortcut is switched off for a run whenever
  the vault's `vault.json` differs from the backed-up one or a
  `rewrap-journal.json` exists on either side, because a recipient change
  rewrites revision files without changing their size (replacing one key by
  another); then every file is compared by hash. A file whose content changed (`vault.json`,
  `rewrap-journal.json`, `keys/`, every revision after a recipient change) is
  replaced and its previous copy kept under `DIR/versions/<UTC time>/<path>`;
  a journal the vault no longer has moves there too. Nothing else is ever
  deleted: revisions the vault no longer has (compaction) stay, unless
  `--prune`, which deletes only those that a snapshot covers that the vault
  and the backup hold byte for byte identically (checked on disk, not from
  the index; the rules of `docs/format.md` §5.3, as `sync` applies them). A file lost from the vault without a covering snapshot is
  never pruned, and neither is an attachment blob
  (`notes/<id>/att/`, `format.md` §8.1.6: collection is per device, so a
  backup keeps every blob it has seen). `--prune` needs the key (exit 4
  without). An interrupted run
  (crash, full disk, Ctrl-C) leaves only complete files; running it again
  finishes the job and removes leftover temporary files.
  `DIR` is itself a vault (`sempere --vault DIR` reads it) plus
  `DIR/backup.json` (vault id, and SHA-256 and size of every file the backup
  wrote) and `DIR/versions/`. Output: `copied`, `replaced` and `pruned` lines
  and a count line (`-v` adds versioned and kept files). `--json` emits
  `vaultId`, `destination`, `copied`, `replaced`, `versioned`, `unchanged`,
  `pruned`, `kept` and `errors` (`{path, message}`). One failing file does not
  stop the run. Exit 0 ok, 1 some files failed, 2 usage, 4 `--prune` without a key.
- `backup V --archive FILE.tar` writes one uncompressed POSIX tar of the
  encrypted files under `<name>.sempere/` (refuses an existing file). It is
  written to a temporary file, read back and checked member by member, then
  renamed. `tar xf FILE.tar` gives back a vault folder. `--json`: `archive`,
  `vaultId`, `files`, `bytes`, `sha256`.
- `backup verify DIR` without a key checks every file in `backup.json` (present,
  same size and SHA-256: a flipped byte or a missing file is found) and that
  `vault.json` is well formed. With `--identity` (or a scripted passphrase for
  the key file the backup holds) it also decrypts, tag-checks and decodes every
  revision like `vault verify`. Files on disk that `backup.json` does not list
  (`unindexed`, from a run cut short) are not problems. Exit 0 healthy, 3
  problems, 4 the key does not open the vault. `--json` emits `healthy`,
  `decrypted`, `backupProblems`, `vaultProblem`, `manifestProblems`,
  `rewrapPending`, `counts` and `files` (`{path, status, detail}`; index
  statuses `ok`, `missing`, `modified`, `unindexed`, plus the vault check's
  problem statuses).
- `restore DIR --to NEWPATH` copies `vault.json`, `keys/` and `notes/` (not
  `versions/` or `backup.json`) into a new or empty folder ending in
  `.sempere`, checking every file against `backup.json`; a file that does not
  match is not restored and is reported. `DIR` may also be any vault folder
  (say, an extracted tar). `vault.json` is written last, so an interrupted
  restore is never mistaken for a vault; the same command finishes it. The
  result is then verified: every revision with `--identity`, structure only
  without. Exit 0 ok, 1 files not restored, 2 usage (`NEWPATH` without
  `.sempere`), 3 the restored vault is not healthy, 4 wrong key.

#### Scheduling backups

A backup run is cheap when nothing changed (it lists and compares sizes), so
run it often. Use absolute paths; no key is needed (do not put one in a
scheduled job unless you use `--prune`).

cron (Linux, macOS), every hour, plus a weekly check:

```cron
0 * * * *  /usr/local/bin/sempere backup /home/me/Sync/notes.sempere --to /mnt/backup/notes -q
30 3 * * 0 /usr/local/bin/sempere backup verify /mnt/backup/notes -q
```

launchd (macOS), `~/Library/LaunchAgents/io.github.anthonytw.sempere-backup.plist`,
then `launchctl load` it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.anthonytw.sempere-backup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/sempere</string><string>backup</string>
    <string>/Users/me/Library/Mobile Documents/com~apple~CloudDocs/notes.sempere</string>
    <string>--to</string><string>/Volumes/Backup/notes</string><string>-q</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardErrorPath</key><string>/tmp/sempere-backup.log</string>
</dict>
</plist>
```

(An iCloud Drive vault must be downloaded on that Mac: an evicted file is not
there to copy. Give `sempere` Full Disk Access if the target is an external
disk.)

systemd user timer (Linux), `~/.config/systemd/user/sempere-backup.service`
and `.timer`, then `systemctl --user enable --now sempere-backup.timer`:

```ini
# sempere-backup.service
[Unit]
Description=Back up the Sempere vault

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sempere backup %h/Sync/notes.sempere --to /mnt/backup/notes -q

# sempere-backup.timer
[Unit]
Description=Hourly Sempere backup

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

A failed run exits non-zero, which cron mails, launchd logs and
`systemctl --user status sempere-backup` shows. For an off-site copy, sync
the backup folder (or a weekly `--archive` tar) with any tool: it holds only
encrypted files.

### Notes

```
sempere notes list [--tag T] [--notebook N] [--deleted] [--no-cache]
sempere notes show ID|TITLE
sempere notes new [TITLE] [--title-format PATTERN] [--notebook PATH] [--tag T]... [--paper KIND] [PAPER OPTIONS] [--page-size letter|a4] [--no-cache]
sempere notes rename ID|TITLE NEW-TITLE
sempere notes tag ID|TITLE [--add T]... [--remove T]... [--no-cache]
sempere notes move ID|TITLE (NOTEBOOK | --none)
sempere notes paper ID|TITLE [KIND] [--page N] [PAPER OPTIONS]
sempere notes search QUERY [--notebook PATH] [--tag T] [--deleted] [--no-cache]
sempere notes delete ID|TITLE
sempere notes undelete ID|TITLE
sempere notes history ID|TITLE [--sessions]
sempere notes restore ID|TITLE --to REVISION [--dry-run]
sempere notes checkpoint ID|TITLE [--name TEXT]
sempere notes layout ID|TITLE paged|pageless [--dry-run]
```

`list` prints id, title, pages, strokes and last modified; deleted notes are
hidden unless `--deleted`. `--notebook` takes a notebook path and lists the
notes in it or below it, comparing whole segments (`A/B` holds `A/B/C` but not
`A/Bc`), as the app's sidebar does; `--tag` ignores case. Notes are read in parallel without their stroke
geometry, and the summaries are kept in an encrypted per-device cache
(`$XDG_CACHE_HOME/sempere/`, default `~/.cache/sempere/`; `format.md` §10), so
a later `list` reads only notes whose revision files changed. A damaged cache
is ignored and rewritten; `--no-cache` neither reads nor writes it. `show` prints the metadata, how many pages have recognised text (`Text:`; `recognizedPages`
in `--json`), the note's placed items (text boxes, images, PDF pages, unknown
kinds; by page in drawing order: page, kind, layer, frame, the text or the
blob's type, size and hash prefix, id) and recordings (start, duration, title,
blob, whether it has a transcript, id), and the revision history
(kind, wall time, file name; `-v` adds the app string). `--json` adds `items`
(each `{page, pageId, item}`, `item` in its `format.md` §8.2 form) and
`recordings` (§8.3.1 form), both without the snapshot-only `origin` and
`clocks`; `list --json` gains the counts `items` and `recordings`. A note is named by its
full id, an id prefix of 4 or more characters, or its exact title
(case-insensitive); an ambiguous name is an error that lists the candidates.

`history` lists the note's restore points, one per readable revision, oldest
first by `(hlc, device, seq)`: kind, wall time, device, app and revision name.
`--json` gives `revision`, `kind`, `hlc`, `device`, `seq`, `wall`, `app`,
`complete`, `checkpoint` (true for a saved version), `name` (the checkpoint's
name, if any), `session` (the editing-session id the app wrote, if any) and
`group` (the index of the point's group, below) per point. A checkpoint is
marked `(checkpoint: NAME)` in the text output. `--sessions` groups the points
as the app's history view does (`docs/format.md` §5.8.2): each checkpoint on
its own, and the autosaves between checkpoints in editing sessions; a new
session starts when the note was closed and reopened (another `session` id),
after a gap of 10 minutes or more, or when another device wrote. The text
output is one line per group (GROUP, FROM, TO, DEVICE, SAVES, NEWEST); `--json`
gives an array of groups, oldest first, each with `type` (`checkpoint` or
`session`), `device`, `session`, `name` (checkpoints), `start`, `end`, `saves`,
`newest` (the revision thinning keeps) and `points` (as above). Snapshots that
`compact` writes "as of" a kept version (`asOf`, `docs/format.md` §5.8.3) are
bookkeeping and are not listed. Revisions deleted by `compact` are not restore points. A
point is `complete: false` (shown as `(incomplete)`) when the note as of it can
no longer be rebuilt: revisions before it were compacted away and no snapshot
at or before it covers them, or one before it (or any snapshot) is unreadable. Unreadable
revisions are not listed; a warning on stderr counts them.

`restore` makes the note look as it did at `REVISION` (the merge of every
revision up to and including it, `docs/format.md` §5.7) by writing **one new
delta**; no existing file is changed or deleted. Pages and strokes added since
are removed, those removed since are re-added under new ids with `parent`
naming the old id, and title, tags, notebook, favorite, paper, page size, page
order, recognition and the deleted flag are set back. Placed items and
recordings follow the same rule (re-added with their register values as of the
point; changed registers such as an item's frame or text or a recording's
title are set back; an item moved to another page since goes back to its page). `REVISION` is a name from
`history`, with or without its `.delta.age`/`.snapshot.age` suffix, or a unique
prefix of 6 or more characters. If the note already matches, nothing is written
(restoring twice is a no-op). `--dry-run` prints what would change
(`would restore ...: remove 1 page(s); re-add 1 stroke(s); set tags`) and
writes nothing. The delta is stamped with this machine's device id and clock,
as for `snapshot`. Restoring needs every revision of the note to be readable;
an incomplete restore point is refused. `--json` emits `note`, `to`, `dryRun`,
`changed`, `file` (the delta written, if any) and `changes` (`pagesRemoved`,
`pagesRestored`, `strokesRemoved`, `strokesRestored`, `pageOrderChanges`,
`recognitionChanges`, `pagePaperChanges`, `itemsRemoved`, `itemsRestored`,
`itemChanges`, `recordingsRemoved`, `recordingsRestored`, `recordingChanges`,
`metaFields`, `deleted`).

`checkpoint` saves the note as it is now as a version, optionally named
(`--name`, trimmed, at most 200 characters): one delta with no ops marked as a
checkpoint (`docs/format.md` §5.8.1), stamped with this machine's device id and
clock as for `snapshot`. The app's Save Version writes the same. Checkpoints are
restore points like any other (`notes restore --to`, `export --at`), and
`compact` never deletes one. `--json` emits `note`, `file`, `name` and
`device`.

`layout` switches a note between paged (fixed-size pages) and pageless (one
infinite page) by writing **one new delta** (`docs/format.md` §5.4.3).
`pageless` joins the pages into the first one, each page's ink shifted down by
its offset, with the old page height as the sheet height (`breakHeight`);
`paged` cuts each infinite page into pages of its sheet height, a stroke going
to the sheet that holds its vertical centre. No ink is deleted and none moves
relative to its sheet; strokes that change page are re-added under new ids with
`parent` naming the old ones, so `pageless` then `paged` gives the pages back.
The switch is computed from the note as it is on disk when the delta is
written. Nothing is written when the note already has the layout (a pageless
note with several pages, left by concurrent edits, is joined), or with
`--dry-run`. A deleted note is refused (exit 1).
The device id and clock are this machine's, as for `snapshot`. `--json` emits
`note`, `layout`, `dryRun`, `changed`, `pagesBefore`, `pagesAfter` and `file`.

`search` finds notes as the app's search box does (`NoteSearch`, shared with
the app): the query is words, and a note matches when every word is found in
its title, notebook, tags or a page's recognised text (case, accents and width
ignored, substrings count); a word starting with `#` matches tags only. Notes
are ranked as in the app (exact title and tag matches first, then the page
holding most of the words) and printed best first with the matching fields,
the best page and a snippet. `--notebook` (that notebook and below) and `--tag`
narrow the search as selecting a notebook or tag in the sidebar does;
`--deleted` searches Recently Deleted instead. `--json` gives `note`, `title`,
`notebook`, `tags`, `fields` (`title`, `tag`, `notebook`, `text`), `page`
(`number`, `id`), `snippet`, `matchedPages` and `score` per note. For every
occurrence of a phrase, with word boxes, use `sempere search`.

#### Editing notes

The editing commands make the same changes as the app's note browser and
canvas, with the same core code (`NoteOps`, `Vault.apply`): each writes **one
delta** per note, stamped with this machine's device id and clock
(`$XDG_STATE_HOME/sempere/device.json`, as for `snapshot`), and nothing at all
when the note already is that way. A note with an unreadable revision is not
edited (exit 1): ops computed from part of a note could undo the rest. Notes
are named as for `show`. With `--json` each prints `note` (the note after the
edit, as in `notes list --json`), `changed` and `file` (the delta written, or
absent).

- `new` creates a note with one blank page: title (trimmed; titles need not
  be unique), notebook, paper (default `ruled`, with the paper options below),
  page size (`letter`, the default, or `a4`) and one `addTag` per `--tag`, in
  the spelling the vault already uses for that tag (as `tag --add` below).
  Prints the new id (the `Created …` line goes to stderr). Without a TITLE
  the note is named after the date and time, as the app names a new note
  (`DefaultTitle`): `--title-format` takes a Unicode date pattern
  (`"yyyy-MM-dd HH:mm"`, literal text in single quotes: `"'Lecture' EEE d MMM"`);
  the default is the locale's medium date and short time. `""` is an empty title.
- `rename` sets the title (trimmed).
- `tag` adds and removes tags in one delta. Tags match case-insensitively and
  merge per tag (`format.md` §5.4.1): `--add` writes an `addTag` unless the
  note has the tag in any spelling, in the spelling the vault already uses
  for it ("math" becomes "Math" if another note has "Math"); `--remove`
  writes a `removeTag` observing every instance of the tag. Adding and
  removing the same tag is a usage error.
- `move` puts the note in a notebook, a `/`-separated path stored in
  canonical form (`" A//B "` is `A/B`); `--none` (or an empty name) takes it
  out of any notebook.
- `paper` sets the paper. Without `--page` the note's paper is set and every
  page with its own paper follows the note again (`setMeta paper` plus
  `setPagePaper null`); `--page N` (1 is the first page) gives only that page
  its own paper (`setPagePaper`). `KIND` starts from that kind's defaults, as
  the app's picker does; without it, the options change the current paper of
  the note (or the page). A deleted note is refused (exit 1). `--json` prints
  `note` (the id), `changed`, `file`, `page` and `paper` (in the format's JSON
  form).
- `delete` moves the note to Recently Deleted; `undelete` brings it back.
  (`restore` is a different thing: it rolls a note back to an earlier
  revision.)

Paper kinds (`format.md` §5.4.2): `blank`, `ruled`, `grid`, `dot`,
`marginRuled`, `isoDot`, `isoGrid`, `cornell`, `staff` (any case; `margin-ruled`
works too). Paper options, in points unless stated; a value outside the
format's limits is a usage error (exit 2), not clamped:

| Option | Range | |
| --- | --- | --- |
| `--spacing` | 4–200 | line, dot or grid spacing |
| `--line-width` | 0.1–4 | rules |
| `--dot-radius` | 0.3–4 | `dot`, `isoDot` |
| `--margin-left`, `--margin-top` | 0–300 | margin lines from the edge; 0 is none |
| `--cue-width`, `--summary-height` | 40–400 | `cornell` |
| `--staff-spacing` | 3–20 | `staff`: between lines |
| `--staff-gap` | 8–150 | `staff`: between staves |
| `--background`, `--line-color`, `--margin-color` | `#RRGGBB` or `#RRGGBBAA` | colours |

```
sempere notes new "Week 3" --notebook School/Physics --tag physics --paper grid --spacing 18
sempere notes paper "Week 3" cornell --page 2
sempere notes tag "Week 3" --add exam --remove draft
```

### Notebooks and tags

```
sempere notebooks list [--deleted] [--no-cache]
sempere notebooks rename OLD NEW [--dry-run]
sempere notebooks move NOTEBOOK (PARENT | --top-level) [--dry-run]
sempere tags list [--no-cache]
```

`notebooks list` prints the notebook tree (parents included, even when they
hold no note directly) with `NOTES`, the notes directly in a notebook, and
`TOTAL`, those in it or below it; deleted notes count only with `--deleted`.
`--json` gives `path`, `depth`, `notes` and `total` per notebook.

`notebooks rename` renames or moves a notebook with everything below it: each
note in `OLD` or below it, deleted ones too, gets the `OLD` prefix of its
notebook replaced by `NEW`, one delta per note (as the app's sidebar rename).
Paths compare by whole segments, so renaming `A/B` leaves `A/Bc` alone. An
empty `NEW` (`""`) takes the notes directly in `OLD` out of any notebook and
lifts its sub-notebooks to the top level. Every note is read first, without
the cache; if any cannot be read the command writes nothing and exits 1 (its
notebook is unknown, so it would be left behind). `--dry-run` lists the notes
that would move. `--json` gives `from`, `to`, `dryRun` and `notes`
(`note`, `title`, `from`, `to`, `file`).

`notebooks move` is what dragging a notebook onto another does in the app (or
"Move Notebook To…"): `NOTEBOOK` keeps its last level and takes `PARENT` as its
parent, so `notebooks move School/Math Archive` makes `School/Math` →
`Archive/Math`, every note below it coming along (the same prefix rename,
deleted notes included, one delta per note, same refusals and `--json` as
`notebooks rename`). `""` or `--top-level` un-nests it. Moving a notebook into
itself or a notebook inside it is a usage error (exit 2, nothing written), and a
notebook that already has the name at the destination is merged with it.
Moving into the notebook it is already in changes nothing. Notes are moved with
`notes move`.

`tags list` prints each tag once (tags match case-insensitively; the first
spelling found is shown, as in the app's sidebar) with the number of notes
that carry it. Deleted notes do not count. `--json` gives `tag` and `notes`.

### Pages

```
sempere pages list ID|TITLE
sempere pages add ID|TITLE [--count N] [--after PAGE]
sempere pages move ID|TITLE PAGE --to PAGE
sempere pages delete ID|TITLE PAGE
sempere pages duplicate ID|TITLE PAGE
```

`list` prints each page's number, id, stroke count, paper (its own, or the
note's marked `*`) and whether it has recognised text. `--json` gives `note`,
`paper` and `pageSize` (the note's) and `pages` (`page`, `id`, `strokes`,
`paper` when the page has its own, `recognized`).

`add` appends `N` blank pages (1–100, default 1) after the last page, or
after page `--after` (0: before the first), in one delta, as the app's Add
Page; they follow the note's paper.

The page gestures of the app (`docs/format.md` §5.4.3), one delta each, with
1-based page numbers as `list` prints them: `move` puts a page at position
`--to` (one `setPageOrder`; nothing when it is already there), `delete`
removes a page and its ink (`removePage`; a note keeps at least one page,
and `notes restore --to` undoes it), `duplicate` copies a page's ink, items,
paper and recognised text right after it under new ids.

A deleted note is refused (exit 1), as is a page number out of range.
`--json` as for the editing commands.

### Items

```
sempere items list ID|TITLE [--page N]
sempere items move ID|TITLE ITEM --frame x,y,w,h
sempere items rotate ID|TITLE ITEM --degrees D
sempere items crop ID|TITLE ITEM (--crop x,y,w,h | --clear) [--keep-frame]
sempere items front ID|TITLE ITEM
sempere items delete ID|TITLE ITEM...
sempere items duplicate ID|TITLE ITEM... [--dx PT] [--dy PT]
sempere items copy ID|TITLE ITEM... --to ID|TITLE [--page N]
```

The app's gestures on placed items (text boxes, images, PDF pages;
`docs/format.md` §8.2), one delta each, built by the same `NoteOps` item
builders as the app's canvas and computed from the note as it is on disk when
the delta is written. An item is named by its id or an id prefix of at least
4 characters (an ambiguous prefix is refused); the items of one command must
be on one page. `list` prints page, id prefix, kind, frame and attachment
(`--json`: `page`, `id`, `kind`, `layer`, `frame`, `rotation`, `z`, `blob`, `crop`).
`move` sets the frame (move and resize; a text box with stored `breaks` that
gets another width is laid out again with the CLI's fonts, its new `breaks`
and the height of its lines written in the same delta, as the app does), `rotate` the rotation, `crop` the
part of an image or PDF page shown (`--crop` in the source's coordinates:
pixels of the upright image, or points on the PDF page's visible box; clamped
to the source; `--clear` shows all of it): the frame follows so the part that
stays visible keeps its place and size on the page, as the app's Crop, unless
`--keep-frame` (`NoteOps.setCrop`; a text box is refused), `front`
draws the item above the others of its layer, `delete` removes items (their
attachments stay until `blobs gc`), `duplicate` copies them on their page
shifted by 20 points (or `--dx`, `--dy`), and `copy` copies them to a page of
another note, its attachments first (verified as they are read), as the app's
Paste. Nothing is written when the item already is that way; a deleted note
is refused (exit 1). `--json` as for the editing commands.

### Import

```
sempere import notability PATH... [--notebook N] [--overwrite] [--dry-run] [--no-scale]
                                   [--no-folder-tags] [--tag T ...] [--no-attachments]
                                   [--keep-image-metadata] [--recognize missing]
```

Each `PATH` is a `.note` or `.ntb` file, an unzipped `.note` package
directory, a folder searched recursively for both, or a zip of them
(Notability's Google Drive backup; pass **every part** of a backup Drive split
into several zips in one run); see `docs/import-notability.md` for the
mapping. All inputs are read before anything is written, so copies of one
note anywhere in them are resolved together: the newest `.note` with ink is imported,
copies whose strokes it already has are skipped (`duplicate:`, `older
version:`, or `superseded:` for an `.ntb` copy, each naming the source that
was imported), and a copy holding strokes the chosen one lacks is imported as
a separate note titled `<title> (version modified <date>)` and gets a
`separate version …` line. An `.ntb` without a `.note` is imported from the
bundle.

One row is printed per input file (status, title, notebook, strokes written,
pages with recognised text, source) plus a summary line; `-v` lists what was
left behind (typed text, PDFs and their page count, media, recordings, PDF
highlights, template PDF paper, dashed strokes, strokes with defaulted
attributes, shapes or `.ntb` strokes not decoded, `.ntb` strokes placed at the
page edge) and one `attachments …` line per attachment warning (a PDF that is
missing, encrypted or unreadable, a page number beyond the PDF, a media object
with no file or no frame together with its Notability field names, an image
format the vault does not store, and how each image was placed).

Attachments (`docs/import-notability.md` "Attachments"): the PDF pages of a
note made from a PDF become `pdfPage` backgrounds at the bands where
Notability showed them, backed by the original PDF as one blob of the note,
images become `image` items, typed text becomes `text` items (styles mapped
to runs), and recordings become the note's recordings with their audio
(strokes get `rec` where `eventTokens` read as times in the one recording);
blobs are written before the note's delta.
JPEG and PNG metadata (camera, location) is stripped unless
`--keep-image-metadata`; HEIC is stored as is; GIF, TIFF, WebP and other
formats are reported and left out. `--no-attachments` imports ink, recognised
handwriting and metadata only and reports every attachment as dropped. A note with
no ink and none of its PDF pages imported gets a `no ink in …` line. A note
already in the vault is skipped unless `--overwrite`, which
replaces its pages. `--notebook` files every note under one notebook;
`--no-scale` keeps Notability's document units instead of scaling to 612 pt
width. Notes are tagged with their Notability folder names (`Research/Daily
log` → `Research`, `Daily log`, besides Notability's own tags; matched
case-insensitively) unless `--no-folder-tags`; `--tag T` (repeatable) adds T
to every imported note. Tags are written as a whole, so `--overwrite` of a
note that moved folders drops the old folder's tags. The device id and clock
come from `device.json` as for `snapshot`.

`--recognize missing` reads the handwriting of every imported page that has
ink but no recognised text (Notability never indexed it) right after the
import, as `sempere recognize --missing-only` does (see "Handwriting
recognition"); Notability's own recognition is never replaced. It needs
macOS: elsewhere the import is refused before anything is written (exit 1).
With `--dry-run` it lists the pages it would read. `--json` then adds
`recognized`, one entry per imported note as in `recognize --json`.

`--dry-run` imports into a throwaway copy of the vault with a throwaway device,
so the report is exact but neither the vault nor `device.json` is touched.
`--json` emits `summary` (`notes`, `imported`, `skipped`, `failed`,
`strokes`, `ntb`, `extraVersions`, `dryRun`, and over the notes written
`pdfPages`, `images`, `textItems`, `recordings`, `recLinkedStrokes`, `blobs`,
`blobBytes`, `droppedPDFPages`, `droppedMedia`) and `notes` (with `status` `imported`, `skipped` or `failed`,
`reason`, `id`, `format` `note`/`ntb`, `shapes`, `duplicateOf`,
`extraVersion`, `selection`, `dropped` (`pdfs`, `pdfPages`, `media`,
`pdfHighlights`, `templatePDFs`, `typedTextCharacters`, `recordings`,
`recLinks`, …), `attachments` (`pdfs`, `pdfPages`, `templatePages`, `images`,
`textItems`, `textCharacters`, `recordings`, `recLinkedStrokes`, `blobs`,
`blobBytes`) and `warnings`, ...). A skipped note's `dropped` counts
everything its source holds, since nothing of it was written. Exit 1
if any note failed, a path does not exist, or no `.note` or `.ntb` file was
found.

#### `import pdf`

```
sempere import pdf FILE... [--title T] [--notebook N] [--tag T ...] [--pages 1-3,5,7-] [--dry-run]
```

Makes a **new note from each PDF**: the PDF is stored as one blob of the note
and every page becomes a note page with a `pdfPage` item filling it in the
background layer, so the note opens as a PDF to annotate (`docs/attachments.md`
§8). The note's page size is the first page's effective size (crop box,
rotation); later pages of another size are fitted and centred; paper is blank.
The whole note is one delta. The title is `--title` (one file only) or the file
name without `.pdf`; `--notebook` and `--tag` as for `notes new`; `--pages`
imports a subset. Encrypted PDFs (remove the password first, e.g. `qpdf
--decrypt`), non-PDFs and PDFs with more than 2 000 pages are refused. Prints
each new note's id (`-q`: only the ids); a file that fails does not stop the
others and the exit code is 1. `--dry-run` checks the files and writes nothing.
`--json` emits `{dryRun, imported, failed, notes}`, one entry per file:
`source`, `status` (`imported`, `would import`, `failed`), `reason`, `id`,
`title`, `pages`, `blob`, `file`. Exports draw the pages as the originals (see
"PDF page backgrounds").

### Search

```
sempere search TERM [--transcripts]
```

(To find notes rather than every occurrence, ranked as in the app, use
`notes search`.)

Case-insensitive, accent-insensitive substring search over every page's
recognised handwriting text (the Notability import, on-device recognition)
**and the text of every text box**, in all notes except deleted ones. With
`--transcripts` it also searches the transcript of every recording, which means
decrypting each transcript blob (a transcript that cannot be read is reported
on stderr and makes the exit code 1). Human output is one row per hit: note
title, where (`p3` handwriting on page 3, `p3 text` a text box, `rec 12:03
Title` a transcript segment at that time) and a snippet. `--json` emits a list
of hits with `noteId`, `title`, `notebook`, `snippet`, `matches`, `source`
(`handwriting`, `text` or `transcript`) and per source: `page` (1-based),
`pageId`, `engine` and `words` (the recognised words containing the term with
their `[x, y, w, h]` boxes) for handwriting; `page`, `pageId`, `itemId` and `box`
(the text box's frame) for text; `recordingId`, `recordingTitle`, `start`,
`end` (seconds), `engine` for a transcript (no `page`). No match prints `No
matches.` (an empty list with `--json`) and exits 0. Notes are read in parallel
and without stroke geometry, as for `notes list`.

`--show-boxes` reports where each match is, as the app's "3 of 12" stepper
does: every recognised word containing a word of the term, numbered across the
note (pages in order, words in reading order). Human output adds one line per
match (`NOTE p.PAGE  N of M  WORD  [x, y, w, h]`); with `--json` every hit gains
`locations`, a list of `{n, of, text, box}` for the matches on that hit's page
(`n` counts from 1 over the whole note, `of` is the note's total).

### Handwriting recognition

```
sempere recognize (ID|TITLE... | --all) [--missing-only | --force] [--dry-run]
```

Reads the handwriting of notes with Apple's Vision, on this machine (nothing
leaves it), and stores the text and word boxes as each page's recognition
(`format.md` §5.5) for `search`, `notes search` and exports. It is the app's
recognition, with the same code: the pages chosen (`RecognitionPolicy`), the
image read (`RecognitionImage`: the ink black on white, markers left out,
cropped to the ink with a 24 pt margin, at 2x or less for large ink) and the
mapping of Vision's lines and word boxes (`VisionText`). The CLI draws the
image with its own renderer where the app uses PencilKit. Each note gets one
delta of `setPageRecognition` ops, stamped with this machine's device id and
clock, and each recognition a `basis` (the digest of the strokes read), so it
is read again only when its ink changes.

Which pages are read:

| Mode | Pages |
| --- | --- |
| default | recognition missing or out of date (ink changed since); Notability's recognition, which cannot be checked, is kept |
| `--missing-only` | only pages with ink and no recognition at all |
| `--force` | every page with ink, replacing any recognition, Notability's included |

A page whose ink is gone has its recognised text cleared (except
Notability's, unless `--force`). A page with only marker strokes gets empty
text. Deleted notes are skipped by `--all` and refused when named. `--dry-run`
lists the pages without reading or writing anything, and works on every
platform.

**macOS only.** Vision is an Apple framework; the Linux build exits 1 with a
message and changes nothing (`--dry-run` still works). Text and JSON output
list per note the pages `read` and `cleared` and the `file` written; `--json`
gives `{dryRun, notes: [{note, title, read, cleared, file, error}]}`. A note
that cannot be read or written is reported and the exit code is 1.

### Transcription

```
sempere transcribe (ID|TITLE [RECORDING...] | --all) [--language TAG] [--engine auto|speechtranscriber|sfspeech]
                   [--force] [--dry-run] [--no-download]
sempere transcribe --check [--language TAG]
```

Transcribes a note's recordings on this machine with Apple's Speech framework
and stores each transcript (`format.md` §8.3.2: time-stamped segments, every
word with its time and confidence, the language and the engine) as a blob of
the note, then sets it on the recording: one delta of `setRecording` ops per
note, stamped with this machine's device id and clock. It is the app's
engine, with the same code (`SpeechTranscription`, `Sources/SempereSpeech`):

| Engine | When | Notes |
| --- | --- | --- |
| `speechtranscriber` | macOS 26 and later | SpeechAnalyzer with SpeechTranscriber, long-form, word times and confidence; the on-device model for the language is installed on first use (Apple's asset service; `--no-download` refuses instead) |
| `sfspeech` | fallback | `SFSpeechRecognizer` with `requiresOnDeviceRecognition`; needs the speech recognition permission, which a command-line program cannot ask for, so from the CLI it works only once that permission was granted |

Nothing is ever sent to a server: a language without an on-device model is an
error. The language is `--language`, else the note's language (`format.md`
§5.4 `lang`, once notes carry it), else this machine's; it is matched to a
supported one (the same tag, else the same language with this machine's
region, else the first of that language). Each recording's audio is decrypted
into a private temporary file (mode 0600) for the recogniser and deleted
afterwards.

By default only recordings without a transcript are read; recordings named on
the command line (id, id prefix of 4+ characters, or exact title) are read
whatever they have, and `--force` replaces every transcript. `--dry-run` lists
what would be read and works on every platform. `--check` prints which engines
can transcribe here, for which language, and needs no vault (it is the
availability matrix of task E5; `--json` gives `{supported, engines: [{engine,
available, language, detail}]}`).

**macOS only.** The Linux build exits 1 with a message and changes nothing
(`--dry-run` and `--check` still work). `--json` gives `{dryRun, notes: [{note,
title, file, error, recordings: [{id, title, engine, language, segments, words,
transcript, error}]}]}`; a recording that cannot be transcribed is reported
and the exit code is 1.

### Export

```
sempere export (ID|TITLE | --all) --format pdf|svg|png|json|markdown|html --out PATH
                [--merge] [--deleted] [--no-paper] [--dpi N] [--at REVISION] [--breaks gaps|fixed]
                [--notebook NAME] [--images none|png] [--clean]
                [--pdf-renderer auto|poppler|none] [--pdf-timeout SECONDS]
                [--assets DIR] [--keep-image-metadata] [--recordings none|attach]
```

- `--at REVISION` (single note only) exports the note as it was at that
  revision, named as for `notes restore --to`.

- `pdf`: one file per note; `--merge` puts every selected note in one PDF
  (`--out` is then the file). A paged note gives one PDF page per page (plus,
  rarely, pages for ink a concurrent edit left below a page). A pageless page
  is cut into pages of its sheet height (`breakHeight`, else width × 11/8.5);
  with `--breaks gaps` (the default) a cut that would cross ink moves up, by
  at most a quarter page, to the top of that ink, so lines of handwriting are
  not cut in half; `--breaks fixed` cuts at every sheet height
  (`docs/format.md` §5.4.3, "Exporting"). Cornell paper is always cut at
  sheets.
- `svg`: one file per page (a pageless page is one tall image). A single note gives `<name>-p001.svg`,
  `<name>-p002.svg`, ... in the output directory; with `--all` each note gets a
  subdirectory, `<name>/p001.svg`, `<name>/p002.svg`, ...
- `png`: one RGBA8 image per page, written like `svg` (`<name>-p001.png`, ...,
  or `<name>/p001.png` with `--all`). Pure Swift, no system imaging library.
  Paper, strokes and tool opacity match the PDF; edges are anti-aliased. An
  infinite page is split into images exactly as it is split into PDF pages
  (`--breaks` applies), so
  numbering counts output pages. `--dpi N` sets the resolution (default 144,
  i.e. 2x the 72 pt/inch page; `0 < N <= 2400`, else exit 2). An image over
  40 million pixels (a letter page above about 620 dpi) is an error naming the
  limit, not an allocation; lower `--dpi`. With `--no-paper` the background is
  transparent.
- `json`: the reconstructed note (`NoteState`, `docs/format.md` §6), items and recordings included.

Every item kind is drawn by `pdf`, `svg` and `png`: text boxes (bundled fonts and font packs, "Text in
exports"), images ("Images in exports") and PDF pages ("PDF page backgrounds"), from the
note's own blobs. Pages never show recordings. `--recordings attach` (PDF only; the app's "PDF +
attachments") embeds each note's recordings as PDF file attachments (`/Names /EmbeddedFiles`,
PDF 1.4: the audio byte for byte, named after the recording's title, and its transcript as a
`.txt` of time-stamped lines); viewers list them and play or save them (`pdfdetach -list`
shows them). At most 512 MiB of recordings go into one PDF; the rest are left out with a
warning. Without it (`none`, the default) a PDF export warns "N recordings not exported". The
`--recordings list` page and `--format media` of task C4 are not done yet; `json` and `notes
show` list recordings.

- `markdown` and `html`: a folder tree, see "Markdown and HTML exports" below.
  `--notebook NAME` (with `--all`, any format) keeps only notes in that
  notebook or below it (whole segments, case-sensitive, `NotebookPath`).

File names are the sanitised title plus the first 8 characters of the note id
(`Physics-Week-3-0d1c6a1e.pdf`). `--out` is a directory (created if needed),
except that a single note's pdf/json goes to the file when `--out` ends in
`.pdf`/`.json`. `--all` skips deleted notes unless `--deleted`; a deleted note
named explicitly is exported with a warning. One note that fails to
reconstruct does not stop the others; the exit code is then 1. Every file
written is printed. With `--json`, each entry has `note`, `files` and, when
some items were drawn as placeholders, `placeholders` (their number), and
`recordings` (the number embedded) with `--recordings attach`.

#### PDF page backgrounds

A `pdfPage` item (an annotated PDF, `docs/format.md` §8.2.6) is read from the
note's attachments, verified (`docs/format.md` §8.1.4), and drawn under the ink:

- `pdf` copies the original page into the export as a Form XObject: exact
  vectors, text and images, on every platform, with no renderer. The file is
  PDF 1.7 when it holds such pages. Only the page's content and resources are
  copied (annotations, form fields and metadata are not). A page whose content
  uses a stream filter the reader does not decode (anything but Flate, LZW,
  ASCII85, ASCIIHex and RunLength) is rasterized by the renderer below, or is a
  placeholder.
- `svg` and `png` need the page as pixels. `--pdf-renderer auto` (the default)
  uses Poppler's `pdftoppm` when it is installed (`$SEMPERE_PDFTOPPM`, else
  `pdftoppm` on `PATH`; `apt install poppler-utils`, `brew install poppler`);
  `poppler` requires it (exit 1 when it is missing); `none` never runs it. SVG
  embeds the page as a PNG data URI clipped to the item's frame (at 2 pixels
  per drawn point); PNG composites it at `--dpi`. A page is drawn with at most
  16 million pixels, and one export rasterizes at most 256 million.
- Poppler runs as a separate process on a private temporary copy of the
  verified PDF (deleted afterwards), started with an argument vector (never a
  shell) and under resource limits: `--pdf-timeout` seconds of wall-clock time
  per page (default 30; then SIGTERM, then SIGKILL), as much CPU time, 3 GiB
  of address space where the OS enforces it, an output file no larger than the
  requested pixels need, no core dumps. A PDF that makes Poppler hang, crash
  or write garbage costs at most one timeout and becomes a placeholder.
- Anything that cannot be drawn (no renderer, a missing or invalid
  attachment, an unreadable or encrypted PDF, a failed render, an item kind
  this export does not draw yet) is a placeholder: the item's frame outlined in
  grey with both diagonals (`docs/format.md` §8.5.2). The export still
  succeeds (exit 0) and prints one warning per kind of problem, e.g.

  ```
  sempere: warning: 0d1c6a1e: 12 PDF background pages drawn as placeholders: install poppler (pdftoppm) to render them, or export as PDF, which keeps them exactly
  sempere: warning: 0d1c6a1e: pdfPage item drawn as a placeholder (PDF renderer failed: pdftoppm timed out after 30 s)
  ```

`markdown` draws `pdfPage` items in its PDF (and per-page PNGs), `html` in its
SVG pages, as above.

#### Images in exports

Image items (`docs/format.md` §8.2.5) are drawn from the note's attachments
(`notes/<id>/att/`), each blob decrypted and checked against its reference
(§8.1.4) before use. Placement follows §8.5.1 (EXIF orientation, crop, frame,
rotation); images are clipped to their frame, under the ink.

- `pdf`: a JPEG is embedded as stored (`DCTDecode`, never re-encoded); PNG
  (and anything else decoded) as lossless 8-bit RGB or grey with a soft mask
  for transparency. One copy per image however many pages use it.
- `svg`: each image as a `data:` URI. `--assets DIR` (svg only) writes each
  image once into `DIR` instead (named by a hash of its bytes, `.jpg`/`.png`)
  and links it with a path relative to the SVG files.
- `png`: images are decoded and resampled into the page (a JPEG decoded at
  1/2, 1/4 or 1/8 size when that is all the output needs).
- **Metadata:** location and camera data (JPEG APPn segments other than JFIF,
  ICC and Adobe; COM; PNG text, `eXIf` and other ancillary chunks; anything
  after the image's end) is removed from every image an export carries,
  whatever is stored, unless `--keep-image-metadata`.
- **Placeholders:** an item that cannot be drawn is a crossed-out grey box
  (§8.5.2) and a warning on stderr, as for PDF pages above, e.g.
  `sempere: warning: 0d1c6a1e: image item drawn as a placeholder (HEIC images
  cannot be decoded here (convert it to JPEG in the app))`. Causes: a missing, unreadable or
  damaged attachment; HEIC (the CLI has no HEVC decoder; the app exports it);
  CMYK, 12-bit, lossless or arithmetic-coded JPEG; an image over 100
  megapixels (§8.4) or over 64 MiB; unknown item kinds. The export still
  succeeds; with `--json` each note's `placeholders` counts them. `markdown`
  and `html` exports draw images too.

#### Text in exports

Text boxes (`docs/format.md` §8.2.4) are laid out as §8.5.3 says: on the lines
the writer stored (`breaks`), else broken by the Unicode line breaking
algorithm (UAX #14) to the frame width; each line is reordered for right-to-left
text (UAX #9) and aligned; every line sits at the same height on every renderer.

- **Fonts.** The CLI ships Noto Sans, Noto Serif and Noto Sans Mono (Latin,
  Greek, Cyrillic; regular, bold, italic, bold italic) under the SIL Open Font
  License 1.1, as files next to the program (`fonts/` in the release archive,
  `share/sempere/fonts` with Homebrew; `$SEMPERE_BUNDLED_FONTS` overrides).
  Other scripts come from **font packs**: any `.ttf`, `.otf`, `.ttc` under
  `$SEMPERE_FONT_DIR`, `$XDG_DATA_HOME/sempere/fonts` (default
  `~/.local/share/sempere/fonts`) and the system font directories
  (`/usr/share/fonts`, `/usr/local/share/fonts`, `~/.fonts`,
  `~/.local/share/fonts`, and on macOS `/Library/Fonts`,
  `/System/Library/Fonts`, `~/Library/Fonts`), searched in that order and only
  when a character needs them. The box's `lang` (or a run's) picks among
  Chinese, Japanese and Korean faces (`ja` → JP, `ko` → KR, `zh-Hant` → TC,
  `zh-HK` → HK, other `zh` → SC). On Debian or Ubuntu, `fonts-noto-cjk` and
  `fonts-noto-core` cover nearly every script.
- **Shaping.** Arabic and other joining scripts get their initial, medial,
  final and isolated forms and required ligatures; Hebrew and Arabic marks are
  attached to their letters. Scripts that need a full shaping engine (Indic
  conjuncts, Khmer, Myanmar, ...) are drawn unshaped with a warning that they
  are approximate (the app's exports of the same note are exact).
- **PDF** embeds, per font used, a subset with exactly the glyphs drawn
  (`ABCDEF+Name`, Type0 / CIDFontType2 or CIDFontType0C) and a `ToUnicode`
  map, so text can be searched and copied (`pdftotext` extracts it).
- **SVG** embeds the same subsets as `@font-face` data URIs. The visible
  glyphs are addressed through private-use code points, so every viewer draws
  exactly the shaped glyphs; an invisible `<text>` per line over them holds the
  real characters for selection, search and copying.
- **PNG** fills the glyph outlines.
- **Missing scripts.** A character no available font covers is drawn as the
  missing-glyph box and reported, naming the script and what to install, e.g.
  `sempere: warning: 0d1c6a1e: page 2: item 6f1c2d4e: text uses Han (Chinese,
  Japanese, Korean) characters (e.g. 汉, U+6C49); no installed font covers
  them, so they are drawn as boxes (install fonts-noto-cjk or put a font in
  ~/.local/share/sempere/fonts or $SEMPERE_FONT_DIR)`.
- A text box that cannot be laid out (no shaper: library callers that pass
  no `RenderOptions.shaper`, such as the app's share export until it has
  one) is a placeholder, reported like any other.

#### Markdown and HTML exports

> **These formats write your notes as PLAINTEXT.** The vault is end-to-end
> encrypted; `--format markdown|html` decrypts it into ordinary files (text,
> PDF, PNG, SVG) that anyone with access to the folder can read, and that
> cloud-sync or backup tools will copy. Choose the output folder accordingly
> (an encrypted volume, not a synced public folder). Nothing is encrypted again.

`--out` is always a directory. Notebooks mirror as folders: the notebook
`School/Math` (`format.md` §5.4) is `School/Math/`; each segment is sanitised
like a file name (`ExportName.component`) and names that differ only by case
share one folder. Notes without a notebook sit in the root. File names are
`ExportName.stem` (title + 8 id characters), so two notes with the same title
never collide; for markdown `[ ] # ^` in the stem also become `-` (they break
Obsidian wikilinks). A segment or stem is at most 120 UTF-8 bytes (file names are
limited in bytes, not characters); a notebook folder named like a Windows device
(`CON`, `NUL`, `COM1`, ...) or like an index file the export writes (`README.md`,
`index.html`) gets a `_` appended. The `.sempere-export-<format>.json` manifest is
not trusted: entries that would leave `--out` are ignored, so a doctored one in a
shared folder cannot make an export write or `--clean` delete elsewhere.

`--format markdown` writes, per note:

- `<stem>.md`: YAML front matter, then the PDF, then one section per page that
  has an image or recognised text. Front matter keys: `title`, `id`, `created`,
  `modified` (UTC, `...Z`; `modified` is the newest revision's wall time),
  `tags` (a list; `[]` when none; Obsidian-safe: `#` dropped, whitespace
  becomes `-`, case-insensitive duplicates merged), `notebook` (canonical
  path, omitted when none), `favorite` (only when true), `pages`, `source`
  (`sempere:<vault id>`). Every string is a double-quoted YAML scalar with
  `"` `\` newlines, control characters and U+0085/U+2028/U+2029 escaped; other
  Unicode is kept as is.
- `<stem>.pdf` (the PDF writer), embedded as `![[<stem>.pdf]]` and linked as a
  standard Markdown link.
- With `--images png`: `<stem>-assets/p001.png`, ... (the PNG writer, `--dpi`
  and `--no-paper` apply; a page that spans several images adds
  `p001-2.png`, ...), embedded as `![Page N](...)` under `## Page N`.
- Recognised text (`format.md` §5.5), when a page has it, under that page as
  `Machine-recognized text (engine ..., may contain errors):` followed by a
  fenced `text` block, so it stays literal and Obsidian or `grep` finds it.
- The text of the page's text boxes, in drawing order, under `Typed text:` as
  fenced `text` blocks (a page with only typed text gets a section too).
- `README.md` in the root and every folder: sub-notebooks and notes (title,
  pages, modified, tags). These list every note the output folder has been
  exported with, not only this run's.

`--format html` writes one self-contained `<stem>.html` per note (inline SVG
pages from the SVG writer; light and dark CSS; title, notebook, dates and
tags; a link back to the index) and `index.html`: notes grouped by notebook
and a search box filtering as you type over title, notebook, tags and
recognised text (a few lines of inline script; the page works without it,
unfiltered). Recognised words are also laid over the ink as an invisible
selectable SVG text layer, and each page's text is listed below it in a
collapsed "Machine-recognized text" block, and the text of its text boxes in a
collapsed "Typed text" block; the index search covers both. There are no external resources:
no scripts, fonts, stylesheets or images are fetched, and the file is
well-formed XML as well as HTML.

**Re-export.** Each file is rewritten only if its content would change
(`Wrote ...` lists those; the last line counts written and unchanged files), so
re-running is cheap for sync tools and keeps timestamps. The export records
what it wrote in `.sempere-export-<format>.json` in `--out`. Renamed, moved or
deleted notes leave their old files until `--clean` (needs `--all`): it removes
files recorded there that this run did not produce (restricted to the
`--notebook` filter, if any), and the folders that leaves empty. It never
touches files it did not write. A note that fails to export keeps its old files.
`--json` lists `note`, `files` and `changed` per note.

### Recover

```
sempere recover FILE.age [--note-id UUID] [--identity FILE ...] [--vault PATH] [--no-verify]
```

Given an attachment blob (`notes/<id>/att/<name>.<kind>.age`) it prints the
blob's content, byte for byte what
`age -d -i KEY FILE | tail -c +46 | head -c LEN` prints (`format.md` §8.1.7).
Framing, zero padding and the content hash are always checked; the file name
too when a vault is known (a name that does not verify: exit 1, nothing
printed); otherwise `UNVERIFIED NAME: ...` goes to stderr. Content streams as
it is decrypted: if the command fails midway, discard the output.

Decrypts one revision file and prints its JSON to stdout, byte for byte what
`age -d -i KEY FILE | tail -c +38 | gunzip` prints. It needs only an identity
file and the one `.age` file. If a vault is known (`--vault`, else `vault.json`
found in a parent directory of the file, else `$SEMPERE_VAULT`) and the identity
opens it, the inner HMAC tag is verified (the note id is the
file's directory name unless `--note-id` says otherwise); otherwise
`UNVERIFIED: ...` is printed to stderr and the JSON is printed anyway. A tag
that does not match is an error (exit 1, nothing printed; the message points to
`--no-verify`). `--no-verify` is for damaged vaults: on a mismatch it prints the
body anyway, writes `WARNING: tag mismatch, content may be tampered or from
another vault` to stderr and exits 3 so scripts can tell. Wrong key: exit 4.

### Maintenance

```
sempere compact (ID|TITLE | --all) [--retention DAYS | --thin-older-than AGE | --thin-all] [--dry-run] [--no-cache]
sempere snapshot ID|TITLE
```

`compact` deletes only what a snapshot makes redundant and what is older than
`--retention` days (default 30), per `docs/format.md` §5.3. When a note has
deltas past the retention window that no snapshot covers (always the case for a
note with no snapshot, once it has anything that old), it
writes a snapshot first (device id and clock as for `snapshot`), then compacts.
`--dry-run` writes and deletes nothing and lists `would snapshot` and
`would delete` lines. With `--all` a note that cannot be compacted (an unreadable
revision) is reported on stderr, the other notes are still processed, and the
exit code is 1.

Checkpoints (`notes checkpoint`) are never deleted, and each one stays a
complete restore point with the same content: when the revisions a checkpoint
depends on are deleted, `compact` first writes a snapshot *as of* the
checkpoint (`asOf`, `docs/format.md` §5.8.3) and keeps one revision per other
device just after it (a *witness*, §5.8.4 rule 3).

`--thin-older-than AGE` thins instead (`docs/format.md` §5.8.4): `AGE` is days,
as `30d` or `30` (more than 0), or `never` (do nothing). Among the revisions
older than that (the longest run from the oldest revision whose wall times are
all older), it keeps every checkpoint, the newest autosave of each editing
session (the groups of `notes history --sessions`) and the note's newest
revision, and deletes the rest, deltas and snapshots alike. Every kept version
and every newer revision stays a complete restore point with the same content,
and the note's current state is unchanged; to make that so it writes a snapshot
as of each kept version that needs one, before deleting anything. Each of those
is a full copy of the note, so thinning can add bytes while it removes files:
the output says how many it deletes and adds (`Would delete 12 file(s), 48.0 KB;
would add 2 snapshot(s), 310.5 KB.`), with `would snapshot NOTE (as of
REVISION)` lines. Thinning twice with the same age does nothing the second
time. Before the per-file lines it prints the rule it applies and what it keeps
(`Thin versions older than 30 days (dry run). Removes autosaves older than 30
days. Keeps every checkpoint …`).

`--thin-all` is the same rule with no age window ("thin everything except
checkpoints", `docs/format.md` §5.8.4 with a cutoff of zero): every autosave
goes, however recent, except the newest save of each editing session; every
checkpoint (saved versions and imports, §5.8.1) and the note's newest revision
stay. It prints its own rule line. `--retention`, `--thin-older-than` and
`--thin-all` are different modes; give one.

Thinning and compaction decide from each revision's metadata (names, wall
times, checkpoint and session fields, snapshot coverage) which notes have
anything to delete, and read only those in full; that metadata comes from the
summary cache (`docs/format.md` §10, filled by listings; `--no-cache` reads
every note instead). Notes are read, planned and carried out in parallel.

`--json` emits one object per note: `note`, `snapshotNeeded`, `snapshot` (the
first snapshot written; null on a dry run), `snapshots` (each `{file, asOf}`;
`file` null on a dry run, `asOf` set for a positioned snapshot), `files` (the
revisions deleted, or that would be), `witnesses`, `bytesDeleted` and
`bytesAdded`.

`snapshot` writes a snapshot of the note. Both need a
key. Snapshots stamp the file with this machine's
device id and clock from `$XDG_STATE_HOME/sempere/device.json` (default
`~/.local/state/sempere/device.json`), created on first use:

```json
{ "device": "3fa9c01e", "millis": 1760000000000, "counter": 0 }
```

### Sync

```
sempere sync webdav URL --vault V [--user U --password-env VAR] [--device NAME]
                         [--max-blob-mib N] [--dry-run] [--json] [--identity FILE | --passphrase-env VAR]
```

Mirrors the vault folder with a WebDAV collection (`docs/io.md`, "WebDAV
sync"); the server needs no logic. `URL` must be `https://`, or `http://` to
`localhost`, `127.0.0.1` or `[::1]`; anything else is refused (exit 2) before a
request is made, and so are credentials inside the URL. The password is read
from the environment variable named by `--password-env` (default
`SEMPERE_WEBDAV_PASSWORD`) and never from the command line. The vault folder
may be missing or empty: the first run pulls everything.

Revision files are copied to the side that lacks them and never overwritten.
`vault.json` and `rewrap-journal.json` are compared with the last sync (state
in `$XDG_STATE_HOME/sempere/sync/`); a change on one side is copied over, a
change on both keeps both copies (`vault.conflict-<device>-<time>.json` next to
the local file; `--device` names this machine, default the host name) and exits
3. Deletions follow only compaction: a file removed on one side is removed on
the other only if the compaction rules (`docs/format.md` §5.3) allow it with
the revisions held locally, which needs the vault unlocked (`--identity`, or
`--passphrase-env`/`$SEMPERE_PASSPHRASE` for the stored key file); otherwise
it is restored, or, with the vault locked, left alone and listed as skipped.
Each note's attachment blobs (`notes/<id>/att/`) are synced the same way:
streamed from and to disk, a blob file over `--max-blob-mib` (default 1088,
that is 1 GiB of content plus padding) neither uploaded nor downloaded but
reported as an error, never a partial blob under its name on either side.
An interrupted blob download continues from where it stopped on the next
run. A blob removed on one side (by `blobs gc`) is removed on the other only
if no revision of its note references it there and every revision of the
note could be read (`format.md` §8.1.6 rules 1–3); otherwise it is copied
back. Blob paths appear in the output and the JSON report like revisions
(`notes/<id>/att/<name>`).
`--dry-run` makes no request that changes anything and writes nothing; it
lists `would upload`, `would download` and `would delete` lines. It cannot see
files it would first download, so it may under-report deletions.

Output: one line per action, then
`N uploaded, N downloaded, N deleted, N conflicts, N errors` (`-q` hides the
lines, `-v` adds skipped and ignored entries). `--json` prints the report:
`dryRun`, `uploaded`, `downloaded`, `deleted` (`{side, path}`), `conflicts`
(`{path, remoteCopy, detail}`), `errors` and `skipped` (`{path, message}`) and
`ignored` (remote names that are not vault files). One failing file does not stop the
run. Exit 0 ok, 1 errors, 2 usage (including a refused URL), 3 conflicts.

## Worked examples

### Make sure a lost device or key costs nothing

```bash
sempere keys paper --identity ~/.config/sempere/key.txt --vault ~/Sync/notes.sempere --out kit.pdf
lp kit.pdf && rm kit.pdf          # print it, keep it with your passport
sempere backup ~/Sync/notes.sempere --to /mnt/usb/notes-backup
sempere backup verify /mnt/usb/notes-backup --identity ~/.config/sempere/key.txt
```

Later, on a new computer with only the sheet and the backup disk:

```bash
# type the key lines into key.txt (or zbarimg --raw -q photo.png > key.txt)
age-keygen -y key.txt                                  # prints the public key on the sheet
sempere restore /mnt/usb/notes-backup --to ~/notes.sempere --identity key.txt
sempere export --all --format pdf --out ~/notes-pdf --vault ~/notes.sempere --identity key.txt
```

### Move a key to a second device

The vault stores your identity passphrase-wrapped (`vault init --store-key`).
On the second device, with the vault folder synced over:

```bash
sempere keys export --vault ~/Sync/notes.sempere --out ~/.config/sempere/key.txt
# Vault passphrase: ********
export SEMPERE_IDENTITY=~/.config/sempere/key.txt
sempere vault verify --vault ~/Sync/notes.sempere
```

Prefer a key per device? Generate one there and add it from a device that
already has access:

```bash
sempere keys generate --out ~/.config/sempere/key.txt        # prints age1new...
# on the first device:
sempere vault recipients add age1new... --label "linux box" \
    --vault ~/Sync/notes.sempere --identity ~/.config/sempere/key.txt
```

### Export everything to PDF on Linux from a backup

```bash
tar xf notes-backup.tar            # from `sempere backup --archive`: contains notes.sempere/
export SEMPERE_VAULT=$PWD/notes.sempere
export SEMPERE_IDENTITY=~/key.txt
sempere vault verify              # exit 0 = every file decrypts and its tag matches
sempere export --all --format pdf --out ~/notes-pdf
sempere export --all --merge --format pdf --out ~/all-notes.pdf
```

Add `--deleted` to include notes you deleted. With only the passphrase-wrapped
key in the backup, drop `SEMPERE_IDENTITY` and run with
`SEMPERE_PASSPHRASE` set (or answer the prompt).

### Recover one note with nothing but age

You have `key.txt` and one file, `17600...-ab12cd34-3.snapshot.age`, and no
`sempere` binary:

```bash
age -d -i key.txt 17600...-ab12cd34-3.snapshot.age | tail -c +38 | gunzip | jq .
```

A post-quantum key (`AGE-SECRET-KEY-PQ-1...`) needs `age` 1.3 or later (the
official release binaries; distribution packages may be older).

The first 37 bytes of the decrypted body are the `SMPR` header and HMAC tag
(`docs/format.md` §4); `tail -c +38` skips them. Newest snapshot first: it
carries the whole note (title, pages, strokes). With the binary, the same
thing is `sempere recover FILE.age --identity key.txt`, which also checks the
tag when the vault folder is next to the file.
