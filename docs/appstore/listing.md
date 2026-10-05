# App Store listing draft

Limits: name 30 characters, subtitle 30, promotional text 170, keywords 100 (comma-separated,
no spaces needed), description 4000, what's new 4000. TODO(user): every line is a draft.

## Name

**Sempere** is the App Store listing name (decided by the maintainer). InkVault remains the name of
the project, the vault format, the repository and the `inkvault` command-line tool. TODO(user):
check that "Sempere" is available in App Store Connect (names are unique per store; nothing here
could check it) and search the store and trademarks (USPTO TESS, EUIPO).

If the bare name is taken, a name + descriptor listing ("Sempere: Private Notes", up to 30
characters) also works. The bundle id (`io.github.anthonytw.inkvault`) cannot change after the
first upload and is independent of the display name. The Xcode project, scheme and
`CFBundleDisplayName` still say `InkVault`: the app rename (display name, product name, icon
text) is a separate change, to be made before the first upload.

## Subtitle (30)

- Encrypted handwriting notes (27)
- Private ink, your own keys (27)

## Promotional text (170)

Handwritten notes encrypted with keys only you hold. No account, no server, no tracking.
Sync through any folder you already use.

## Description

```
Sempere is a handwriting notes app for iPad and Mac that keeps your notes yours.

YOUR KEYS, YOUR NOTES
Every note is encrypted with the open age format, to keys you generate, import, export and back
up yourself. There is no account to create and no server of ours: nobody but you, not even the
developer, can read what you write.

SYNC IS A FOLDER
A vault is a plain folder of encrypted files. Keep it on your iPad, in iCloud Drive, on a NAS or
behind a WebDAV server, and let the service you already use move it. Edits from two devices
merge; sync tools never create conflict copies.

NOTHING IS LOST QUIETLY
Every save is added to a history you can browse. Mistakes can be restored without erasing the
past.

REAL INK
Write with Apple Pencil using the system tool picker: pens, marker, pencil, eraser, lasso,
rulers. Strokes stay vectors, so export to PDF and SVG is crisp at any size.

READABLE WITHOUT THE APP
Your notes are standard age files. With your key and free tools you can always decrypt them, and
the open-source command-line tool exports PDF, SVG and PNG on Mac and Linux.

SIMPLE ON PURPOSE
Notebooks, tags, paper styles and search. No AI, no ads, no subscription, no analytics.

OPEN SOURCE
Sempere is free software (GPL-3.0-or-later with an App Store exception). Read the code at
github.com/anthonytw/inkvault.

Privacy: Sempere collects no data.
```

TODO(user): trim to what the shipping build really does. At the time of writing the app has
the browser, canvas, vault management and (in progress) key management, export and handwriting
recognition/search; do not describe unfinished features (`docs/plan.md`). "Lasso, rulers" and
"search" need checking against the build; Apple rejects descriptions of missing features.

## Keywords (100 characters)

`handwriting,notes,encrypted,private,pencil,notebook,ipad,pdf,age,e2ee,sketch,journal,offline`
(91 characters; avoid competitors' names, which Apple rejects. Words already in the name and
subtitle are free: do not repeat them.)

## What's new (first version)

```
First release. Handwritten notes encrypted with your own keys, synced through any folder
you choose. No account, no tracking.
```

## URLs and categories

- Primary category: Productivity (project already sets `public.app-category.productivity`);
  secondary: Graphics & Design or Utilities. TODO(user): choose.
- Support URL: TODO(user) (the GitHub issues page works).
- Marketing URL: TODO(user) (the repository, optional).
- Privacy Policy URL: TODO(user): hosted `privacy-policy.md`.
- Copyright: `© 2026 Anthony Wertz`. TODO(user): confirm the name and year.
- Price: free? TODO(user). No in-app purchases, no ads.
- License: the source is GPL-3.0-or-later with the App Store exception (`LICENSE-EXCEPTION`,
  `docs/legal/app-store-exception.md`), which is what lets the project ship under Apple's terms.
  Mention it in the description (above); the Apple standard EULA applies unless you provide a
  custom one (TODO(user)).

## App Review notes (text for the reviewer)

```
Sempere stores notes in a user-chosen folder, encrypted with an age key. To review: choose
"New Vault" → "On This Device", generate a key (shown once; copy it), then create a note and
draw with Apple Pencil or a finger. No account or network access is needed. A sample vault is
not required. The app contains encryption (age: hybrid ML-KEM-768 + X25519, ChaCha20-Poly1305,
HKDF, scrypt) for the user's own data; standard published algorithms at full strength, mass-market
software; see export compliance answers.
```

TODO(user): if a reviewer needs a test vault and key, attach a throwaway vault (the repository's
fixture vault `Tests/InkVaultTests/Fixtures/sample.inkvault` and `sample.key` are throwaway).
