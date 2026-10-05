# The `inkvault` command line

The Linux and macOS face of InkVault: keys, vault management, verification,
export and recovery. It builds with `swift build -c release --product inkvault`
and CI publishes a static Linux binary. The executable only parses arguments,
talks to the terminal and sets exit codes; everything else lives in
`Sources/InkVault` and `Sources/InkRender`.

## Global conventions

| Option | Meaning |
| --- | --- |
| `--vault PATH` | The vault directory (`*.inkvault`). Env `INKVAULT_VAULT`. |
| `--identity FILE` | An age identity file (`age-keygen` style). Repeatable. Env `INKVAULT_IDENTITY` (one path). |
| `--passphrase-env VAR` | Name of the environment variable holding the passphrase of the vault's stored key file. |
| `--json` | Machine-readable output where it makes sense (everything except `recover`, `keys generate` without `--out`, and `keys export` without `--out`). |
| `-q`, `-v` | Quieter (data only, or only problems) / more detail. |
| `--version`, `--help` | On every command. |

`--vault`, `--identity` and `--passphrase-env` apply to the commands that open
an existing vault. Times are printed in your local time zone with an offset;
`--json` uses UTC (`Z`).

**Getting a key.** Commands that read notes need an identity. In order:
`--identity` files (or `$INKVAULT_IDENTITY`); otherwise the passphrase-wrapped
key stored in the vault's `keys/` directory, unlocked with the passphrase from
`--passphrase-env VAR`, else `$INKVAULT_PASSPHRASE`, else a no-echo prompt on
the terminal. A passphrase never goes on the command line. Secret keys are
printed only by `keys generate` and `keys export`.

**Exit codes**

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Generic failure (I/O, bad input, corrupt file, refusing to overwrite). |
| 2 | Usage error (unknown option, missing vault, bad recipient string). |
| 3 | `vault verify` found problems, or a recipient change is incomplete. |
| 4 | Cannot decrypt: wrong key or passphrase, or no key available (no identity, no passphrase and no terminal to ask, or a `--passphrase-env` variable that is not set). |

Errors go to stderr, one line each, prefixed `inkvault:`.

**Environment**

| Variable | Use |
| --- | --- |
| `INKVAULT_VAULT` | Default for `--vault`. |
| `INKVAULT_IDENTITY` | Default identity file. |
| `INKVAULT_PASSPHRASE` | Passphrase for the vault's stored key file, for scripts and tests. |
| `XDG_STATE_HOME` | Where `device.json` lives (default `~/.local/state`). |

## Commands

### Keys

```
inkvault keys generate [--out FILE]
inkvault keys show FILE
inkvault keys export --vault V [--recipient age1...] [--out FILE]
```

- `generate` writes an `age-keygen`-style identity (mode 0600, refuses to
  overwrite) and prints the public key. Without `--out` the identity goes to
  stdout and the public key to stderr.
- `show` prints the public key (`age1...`) of an identity file.
- `export` decrypts the vault's passphrase-wrapped key file
  (`keys/<recipient>.key.age`) to a plain identity file, to move a key to
  another device. `--recipient` is needed only if the vault stores several.

### Vault

```
inkvault vault init PATH --recipient age1... [--recipient ...] [--label TEXT ...]
                         [--store-key FILE [--passphrase-env VAR] [--work-factor 15...18]]
inkvault vault info
inkvault vault recipients add age1... [--label TEXT]
inkvault vault recipients remove age1...
inkvault vault rewrap-resume
inkvault vault verify
```

- `init` creates the vault. `PATH` must end in `.inkvault`. Give no `--label`
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
- `rewrap-resume` finishes an interrupted change.
- `verify` decrypts, tag-checks and decodes every file and prints
  `status  path` per file plus counts. Exit 0 only if the vault is healthy,
  else 3. `-q` lists only problem files. `--json` emits `healthy`,
  `manifestProblems`, `rewrapPending`, `journalProblem`, `counts` and `files`.

### Notes

```
inkvault notes list [--tag T] [--notebook N] [--deleted]
inkvault notes show ID|TITLE
inkvault notes history ID|TITLE
inkvault notes restore ID|TITLE --to REVISION [--dry-run]
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
inkvault import notability PATH... [--notebook N] [--overwrite] [--dry-run] [--no-scale]
```

Each `PATH` is a `.note` file, an unzipped `.note` package directory, a folder
searched recursively for `.note` files, or a zip of `.note` files (Notability's
backup); see `docs/import-notability.md` for the mapping. One row is printed per
note (status, title, notebook, strokes written, pages with recognised text,
source) plus a summary line; `-v` lists what was left behind (typed text, PDFs
and their page count, media, recordings, dashed strokes). A note with no ink
whose pages are PDF pages (a PDF that was never written on) imports as an
empty note and gets a `no ink in …` line, since PDF backgrounds are not imported
yet. A note already in the vault is skipped unless
`--overwrite`, which replaces its pages. `--notebook` files every note under one
notebook; `--no-scale` keeps Notability's document units instead of scaling to
612 pt width. The device id and clock come from `device.json` as for `snapshot`.

`--dry-run` imports into a throwaway copy of the vault with a throwaway device,
so the report is exact but neither the vault nor `device.json` is touched.
`--json` emits `summary` and `notes` (with `status` `imported`, `skipped` or
`failed`, `reason`, `id`, `dropped`, ...). Exit 1 if any note failed, a path
does not exist, or no `.note` file was found.

### Search

```
inkvault search TERM
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
inkvault export (ID|TITLE | --all) --format pdf|svg|png|json|markdown|html --out PATH
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
Obsidian wikilinks).

`--format markdown` writes, per note:

- `<stem>.md`: YAML front matter, then the PDF, then one section per page that
  has an image or recognised text. Front matter keys: `title`, `id`, `created`,
  `modified` (UTC, `...Z`; `modified` is the newest revision's wall time),
  `tags` (a list; `[]` when none; Obsidian-safe: `#` dropped, whitespace
  becomes `-`, case-insensitive duplicates merged), `notebook` (canonical
  path, omitted when none), `favorite` (only when true), `pages`, `source`
  (`inkvault:<vault id>`). Every string is a double-quoted YAML scalar with
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
what it wrote in `.inkvault-export-<format>.json` in `--out`. Renamed, moved or
deleted notes leave their old files until `--clean` (needs `--all`): it removes
files recorded there that this run did not produce (restricted to the
`--notebook` filter, if any), and the folders that leaves empty. It never
touches files it did not write. A note that fails to export keeps its old files.
`--json` lists `note`, `files` and `changed` per note.

### Recover

```
inkvault recover FILE.age [--note-id UUID] [--identity FILE ...] [--vault PATH] [--no-verify]
```

Decrypts one revision file and prints its JSON to stdout, byte for byte what
`age -d -i KEY FILE | tail -c +38 | gunzip` prints. It needs only an identity
file and the one `.age` file. If a vault is known (`--vault`, else `vault.json`
found in a parent directory of the file, else `$INKVAULT_VAULT`) and the identity
opens it, the inner HMAC tag is verified (the note id is the
file's directory name unless `--note-id` says otherwise); otherwise
`UNVERIFIED: ...` is printed to stderr and the JSON is printed anyway. A tag
that does not match is an error (exit 1, nothing printed; the message points to
`--no-verify`). `--no-verify` is for damaged vaults: on a mismatch it prints the
body anyway, writes `WARNING: tag mismatch, content may be tampered or from
another vault` to stderr and exits 3 so scripts can tell. Wrong key: exit 4.

### Maintenance

```
inkvault compact (ID|TITLE | --all) [--retention DAYS] [--dry-run]
inkvault snapshot ID|TITLE
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
device id and clock from `$XDG_STATE_HOME/inkvault/device.json` (default
`~/.local/state/inkvault/device.json`), created on first use:

```json
{ "device": "3fa9c01e", "millis": 1760000000000, "counter": 0 }
```

### Sync

```
inkvault sync webdav URL --vault V [--user U --password-env VAR] [--device NAME]
                         [--dry-run] [--json] [--identity FILE | --passphrase-env VAR]
```

Mirrors the vault folder with a WebDAV collection (`docs/io.md`, "WebDAV
sync"); the server needs no logic. `URL` must be `https://`, or `http://` to
`localhost`, `127.0.0.1` or `[::1]`; anything else is refused (exit 2) before a
request is made, and so are credentials inside the URL. The password is read
from the environment variable named by `--password-env` (default
`INKVAULT_WEBDAV_PASSWORD`) and never from the command line. The vault folder
may be missing or empty: the first run pulls everything.

Revision files are copied to the side that lacks them and never overwritten.
`vault.json` and `rewrap-journal.json` are compared with the last sync (state
in `$XDG_STATE_HOME/inkvault/sync/`); a change on one side is copied over, a
change on both keeps both copies (`vault.conflict-<device>-<time>.json` next to
the local file; `--device` names this machine, default the host name) and exits
3. Deletions follow only compaction: a file removed on one side is removed on
the other only if the compaction rules (`docs/format.md` §5.3) allow it with
the revisions held locally, which needs the vault unlocked (`--identity`, or
`--passphrase-env`/`$INKVAULT_PASSPHRASE` for the stored key file); otherwise
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

### Move a key to a second device

The vault stores your identity passphrase-wrapped (`vault init --store-key`).
On the second device, with the vault folder synced over:

```bash
inkvault keys export --vault ~/Sync/notes.inkvault --out ~/.config/inkvault/key.txt
# Vault passphrase: ********
export INKVAULT_IDENTITY=~/.config/inkvault/key.txt
inkvault vault verify --vault ~/Sync/notes.inkvault
```

Prefer a key per device? Generate one there and add it from a device that
already has access:

```bash
inkvault keys generate --out ~/.config/inkvault/key.txt        # prints age1new...
# on the first device:
inkvault vault recipients add age1new... --label "linux box" \
    --vault ~/Sync/notes.inkvault --identity ~/.config/inkvault/key.txt
```

### Export everything to PDF on Linux from a backup

```bash
tar xf notes-backup.tar            # contains notes.inkvault/
export INKVAULT_VAULT=$PWD/notes.inkvault
export INKVAULT_IDENTITY=~/key.txt
inkvault vault verify              # exit 0 = every file decrypts and its tag matches
inkvault export --all --format pdf --out ~/notes-pdf
inkvault export --all --merge --format pdf --out ~/all-notes.pdf
```

Add `--deleted` to include notes you deleted. With only the passphrase-wrapped
key in the backup, drop `INKVAULT_IDENTITY` and run with
`INKVAULT_PASSPHRASE` set (or answer the prompt).

### Recover one note with nothing but age

You have `key.txt` and one file, `17600...-ab12cd34-3.snapshot.age`, and no
`inkvault` binary:

```bash
age -d -i key.txt 17600...-ab12cd34-3.snapshot.age | tail -c +38 | gunzip | jq .
```

The first 37 bytes of the decrypted body are the `INKV` header and HMAC tag
(`docs/format.md` §4); `tail -c +38` skips them. Newest snapshot first: it
carries the whole note (title, pages, strokes). With the binary, the same
thing is `inkvault recover FILE.age --identity key.txt`, which also checks the
tag when the vault folder is next to the file.
