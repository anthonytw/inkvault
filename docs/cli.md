# The `sempere` command line

The Linux and macOS face of Sempere: keys, vault management, verification,
export and recovery. It builds with `swift build -c release --product sempere`
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
a vault (`notes …`, `export`, `search`, `compact`, `snapshot`, `import`,
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
sempere vault recipients add age1pq1... [--label TEXT] [--store-key FILE [--store-passphrase-env VAR] [--work-factor 15...18]]
sempere vault recipients remove age1...
sempere vault recipients replace age1old... age1pq1new... [--label TEXT] [--store-key FILE ...]
sempere vault rewrap-resume
sempere vault verify
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
sempere notes list [--tag T] [--notebook N] [--deleted]
sempere notes show ID|TITLE
sempere notes history ID|TITLE
sempere notes restore ID|TITLE --to REVISION [--dry-run]
```

`list` prints id, title, pages, strokes and last modified; deleted notes are
hidden unless `--deleted`. `show` prints the metadata, how many pages have recognised text (`Text:`; `recognizedPages`
in `--json`) and the revision history
(kind, wall time, file name; `-v` adds the app string). A note is named by its
full id, an id prefix of 4 or more characters, or its exact title
(case-insensitive); an ambiguous name is an error that lists the candidates.

`history` lists the note's restore points, one per readable revision, oldest
first by `(hlc, device, seq)`: kind, wall time, device, app and revision name.
`--json` gives `revision`, `kind`, `hlc`, `device`, `seq`, `wall`, `app` and
`complete` per point. Revisions deleted by `compact` are not restore points. A
point is `complete: false` (shown as `(incomplete)`) when the note as of it can
no longer be rebuilt: revisions before it were compacted away and no snapshot
at or before it covers them, or one before it (or any snapshot) is unreadable. Unreadable
revisions are not listed; a warning on stderr counts them.

`restore` makes the note look as it did at `REVISION` (the merge of every
revision up to and including it, `docs/format.md` §5.7) by writing **one new
delta**; no existing file is changed or deleted. Pages and strokes added since
are removed, those removed since are re-added under new ids with `parent`
naming the old id, and title, tags, notebook, favorite, paper, page size, page
order, recognition and the deleted flag are set back. `REVISION` is a name from
`history`, with or without its `.delta.age`/`.snapshot.age` suffix, or a unique
prefix of 6 or more characters. If the note already matches, nothing is written
(restoring twice is a no-op). `--dry-run` prints what would change
(`would restore ...: remove 1 page(s); re-add 1 stroke(s); set tags`) and
writes nothing. The delta is stamped with this machine's device id and clock,
as for `snapshot`. Restoring needs every revision of the note to be readable;
an incomplete restore point is refused. `--json` emits `note`, `to`, `dryRun`,
`changed`, `file` (the delta written, if any) and `changes` (`pagesRemoved`,
`pagesRestored`, `strokesRemoved`, `strokesRestored`, `pageOrderChanges`,
`recognitionChanges`, `metaFields`, `deleted`).

### Import

```
sempere import notability PATH... [--notebook N] [--overwrite] [--dry-run] [--no-scale]
                                   [--no-folder-tags] [--tag T ...]
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
left behind (typed text, PDFs and their page count, media, recordings, dashed
strokes, strokes with defaulted attributes, shapes or `.ntb` strokes not
decoded, `.ntb` strokes placed at the page edge). A note with no ink whose
pages are PDF pages (a PDF that was never written on) imports as an empty
note and gets a `no ink in …` line, since PDF backgrounds are not imported
yet. A note already in the vault is skipped unless `--overwrite`, which
replaces its pages. `--notebook` files every note under one notebook;
`--no-scale` keeps Notability's document units instead of scaling to 612 pt
width. Notes are tagged with their Notability folder names (`Research/Daily
log` → `Research`, `Daily log`, besides Notability's own tags; matched
case-insensitively) unless `--no-folder-tags`; `--tag T` (repeatable) adds T
to every imported note. Tags are written as a whole, so `--overwrite` of a
note that moved folders drops the old folder's tags. The device id and clock
come from `device.json` as for `snapshot`.

`--dry-run` imports into a throwaway copy of the vault with a throwaway device,
so the report is exact but neither the vault nor `device.json` is touched.
`--json` emits `summary` (`notes`, `imported`, `skipped`, `failed`,
`strokes`, `ntb`, `extraVersions`, `dryRun`) and `notes` (with `status`
`imported`, `skipped` or `failed`, `reason`, `id`, `format` `note`/`ntb`,
`shapes`, `duplicateOf`, `extraVersion`, `selection`, `dropped`, ...). Exit 1
if any note failed, a path does not exist, or no `.note` or `.ntb` file was
found.

### Search

```
sempere search TERM
```

Case-insensitive substring search over every page's recognised text (the
Notability import, later on-device recognition) in all notes except deleted
ones. Human output is one row per matching page: note title, page number and a
snippet. `--json` emits a list of hits with `noteId`, `title`, `notebook`,
`page` (1-based), `pageId`, `snippet`, `matches`, `engine` and `words`, the
recognised words containing the term with their `[x, y, w, h]` boxes. No match
prints `No matches.` (an empty list with `--json`) and exits 0.

### Export

```
sempere export (ID|TITLE | --all) --format pdf|svg|png|json|markdown|html --out PATH
                [--merge] [--deleted] [--no-paper] [--dpi N] [--at REVISION]
                [--notebook NAME] [--images none|png] [--clean]
```

- `--at REVISION` (single note only) exports the note as it was at that
  revision, named as for `notes restore --to`.

- `pdf`: one file per note; `--merge` puts every selected note in one PDF
  (`--out` is then the file).
- `svg`: one file per page. A single note gives `<name>-p001.svg`,
  `<name>-p002.svg`, ... in the output directory; with `--all` each note gets a
  subdirectory, `<name>/p001.svg`, `<name>/p002.svg`, ...
- `png`: one RGBA8 image per page, written like `svg` (`<name>-p001.png`, ...,
  or `<name>/p001.png` with `--all`). Pure Swift, no system imaging library.
  Paper, strokes and tool opacity match the PDF; edges are anti-aliased. An
  infinite page is split into images exactly as it is split into PDF pages, so
  numbering counts output pages. `--dpi N` sets the resolution (default 144,
  i.e. 2x the 72 pt/inch page; `0 < N <= 2400`, else exit 2). An image over
  40 million pixels (a letter page above about 620 dpi) is an error naming the
  limit, not an allocation; lower `--dpi`. With `--no-paper` the background is
  transparent.
- `json`: the reconstructed note (`NoteState`, `docs/format.md` §6).

- `markdown` and `html`: a folder tree, see "Markdown and HTML exports" below.
  `--notebook NAME` (with `--all`, any format) keeps only notes in that
  notebook or below it (whole segments, case-sensitive, `NotebookPath`).

File names are the sanitised title plus the first 8 characters of the note id
(`Physics-Week-3-0d1c6a1e.pdf`). `--out` is a directory (created if needed),
except that a single note's pdf/json goes to the file when `--out` ends in
`.pdf`/`.json`. `--all` skips deleted notes unless `--deleted`; a deleted note
named explicitly is exported with a warning. One note that fails to
reconstruct does not stop the others; the exit code is then 1. Every file
written is printed.

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
collapsed "Machine-recognized text" block. There are no external resources:
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
sempere compact (ID|TITLE | --all) [--retention DAYS] [--dry-run]
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
exit code is 1. `snapshot` writes a snapshot of the note. Both need a
key. Snapshots stamp the file with this machine's
device id and clock from `$XDG_STATE_HOME/sempere/device.json` (default
`~/.local/state/sempere/device.json`), created on first use:

```json
{ "device": "3fa9c01e", "millis": 1760000000000, "counter": 0 }
```

### Sync

```
sempere sync webdav URL --vault V [--user U --password-env VAR] [--device NAME]
                         [--dry-run] [--json] [--identity FILE | --passphrase-env VAR]
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
